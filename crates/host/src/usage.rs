//! Sub2API adapter, extracted from Orbit without its wire/config/runtime dependencies.
//! Password and short-lived tokens are private to this collector.
use crate::workbench::ApiUsage;
use anyhow::{ensure, Context, Result};
use chrono::{Days, TimeZone, Utc};
use rust_decimal::{prelude::ToPrimitive, Decimal, RoundingStrategy};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{str::FromStr, time::Duration};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UsageConfig {
    pub base_url: String,
    pub email: String,
    pub timezone: String,
}
impl UsageConfig {
    pub fn validate(&self) -> Result<()> {
        let u = url::Url::parse(&self.base_url).context("请输入完整的 Sub2API 网址")?;
        ensure!(
            u.scheme() == "https"
                && u.host_str().is_some()
                && u.username().is_empty()
                && u.password().is_none()
                && u.query().is_none()
                && u.fragment().is_none()
                && self.base_url.len() <= 2048
                && self.base_url.trim() == self.base_url,
            "Sub2API 网址须使用 HTTPS，且不包含登录信息、查询参数或片段"
        );
        ensure!(
            self.email.contains('@')
                && self.email.len() <= 254
                && !self.email.chars().any(char::is_whitespace)
                && !self.email.chars().any(char::is_control),
            "请输入登录邮箱"
        );
        ensure!(
            self.timezone.parse::<chrono_tz::Tz>().is_ok(),
            "请选择有效的时区"
        );
        Ok(())
    }
    fn endpoint(&self, path: &str) -> String {
        format!("{}/api/v1/{path}", self.base_url.trim_end_matches('/'))
    }
}

pub enum Error {
    Unauthorized,
    RateLimited(Duration),
    Unavailable,
    Invalid,
}
impl Error {
    pub fn message(&self) -> &'static str {
        match self {
            Self::Unauthorized => "Sub2API 登录失效，请在连接助手中检查邮箱和密码",
            Self::RateLimited(_) => "请求过于频繁，稍后自动重试",
            Self::Unavailable => "暂时无法连接 Sub2API，上次数据仍可查看",
            Self::Invalid => "Sub2API 返回数据格式不正确，请检查服务版本与时区",
        }
    }
}
pub struct Source {
    config: UsageConfig,
    password: String,
    client: reqwest::Client,
    access: String,
    refresh: String,
}
impl Source {
    pub fn new(config: UsageConfig, password: String) -> Result<Self> {
        config.validate()?;
        ensure!(
            !password.is_empty() && password.len() <= 4096,
            "请输入登录密码"
        );
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("无法初始化用量采集")?;
        Ok(Self {
            config,
            password,
            client,
            access: String::new(),
            refresh: String::new(),
        })
    }
    async fn request(
        &self,
        path: &str,
        body: Option<Value>,
        token: &str,
    ) -> std::result::Result<Value, Error> {
        let url = self.config.endpoint(path);
        let mut request = if let Some(body) = body {
            self.client.post(url).json(&body)
        } else {
            self.client.get(url)
        };
        if !token.is_empty() {
            request = request.bearer_auth(token);
        }
        let mut response = request.send().await.map_err(|_| Error::Unavailable)?;
        match response.status().as_u16() {
            401 | 403 => return Err(Error::Unauthorized),
            429 => {
                let delay = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| {
                        v.parse::<u64>().ok().or_else(|| {
                            chrono::DateTime::parse_from_rfc2822(v)
                                .ok()
                                .map(|t| (t.timestamp() - Utc::now().timestamp()).max(1) as u64)
                        })
                    })
                    .unwrap_or(60)
                    .clamp(1, 86400);
                return Err(Error::RateLimited(Duration::from_secs(delay)));
            }
            200..=299 => {}
            _ => return Err(Error::Unavailable),
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Unavailable)? {
            if bytes.len() + chunk.len() > 8192 {
                return Err(Error::Invalid);
            }
            bytes.extend_from_slice(&chunk);
        }
        let v: Value = serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
        if v["code"].as_i64() != Some(0) || !v["data"].is_object() {
            return Err(Error::Invalid);
        }
        Ok(v["data"].clone())
    }
    fn tokens(&mut self, v: Value) -> std::result::Result<(), Error> {
        let access = v["access_token"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or(Error::Invalid)?;
        let refresh = v["refresh_token"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or(Error::Invalid)?;
        self.access = access.into();
        self.refresh = refresh.into();
        Ok(())
    }
    async fn login(&mut self) -> std::result::Result<(), Error> {
        let v = self
            .request(
                "auth/login",
                Some(json!({"email": self.config.email, "password": self.password})),
                "",
            )
            .await?;
        self.tokens(v)
    }
    pub async fn fetch(&mut self, now: u64) -> std::result::Result<ApiUsage, Error> {
        if self.access.is_empty() {
            self.login().await?;
        }
        let mut result = self
            .request("usage/dashboard/stats", None, &self.access)
            .await;
        if matches!(result, Err(Error::Unauthorized)) {
            match self
                .request(
                    "auth/refresh",
                    Some(json!({"refresh_token": self.refresh})),
                    "",
                )
                .await
            {
                Ok(v) => {
                    if self.tokens(v).is_err() {
                        self.login().await?;
                    }
                }
                Err(e @ Error::RateLimited(_)) => return Err(e),
                _ => self.login().await?,
            }
            result = self
                .request("usage/dashboard/stats", None, &self.access)
                .await;
        }
        parse_usage(&result?, &self.config.timezone, now).map_err(|_| Error::Invalid)
    }
}

pub fn parse_usage(v: &Value, timezone: &str, now: u64) -> Result<ApiUsage> {
    ensure!(v["today_actual_cost"].is_number(), "费用不可用");
    let text = v["today_actual_cost"].to_string();
    let cost = Decimal::from_str(&text).or_else(|_| Decimal::from_scientific(&text))?;
    ensure!(!cost.is_sign_negative(), "费用无效");
    let micros = cost
        .checked_mul(Decimal::from(1_000_000))
        .context("费用超出范围")?
        .round_dp_with_strategy(0, RoundingStrategy::MidpointAwayFromZero)
        .to_i64()
        .context("费用超出范围")?;
    let zone = timezone.parse::<chrono_tz::Tz>()?;
    let local = Utc
        .timestamp_opt(i64::try_from(now)?, 0)
        .single()
        .context("日期无效")?
        .with_timezone(&zone);
    let date = local.date_naive();
    let start = zone
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).context("日期无效")?)
        .earliest()
        .context("日期无效")?;
    let end = zone
        .from_local_datetime(
            &date
                .checked_add_days(Days::new(1))
                .context("日期无效")?
                .and_hms_opt(0, 0, 0)
                .context("日期无效")?,
        )
        .earliest()
        .context("日期无效")?;
    Ok(ApiUsage {
        id: "sub2api".into(),
        label: "Sub2API · 今日".into(),
        actual_cost_micros: micros,
        currency: "USD".into(),
        token_count: v["today_tokens"].as_u64().context("Token 不可用")?,
        tpm: v["tpm"].as_u64().context("TPM 不可用")?,
        window_start: u64::try_from(start.timestamp())?,
        window_end: u64::try_from(end.timestamp())?,
    })
}

impl crate::Host {
    pub fn set_usage_config(&mut self, config: Option<UsageConfig>) -> Result<()> {
        if let Some(c) = &config {
            c.validate()?;
        }
        let previous = std::mem::replace(&mut self.usage_config, config);
        if let Err(e) = self.save(&self.devices) {
            self.usage_config = previous;
            return Err(e);
        }
        // Never show a previous account's data under a newly selected source.
        self.workbench.api_usage.clear();
        self.workbench
            .sources
            .retain(|s| s.source_id != "sub2api.usage");
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(
        responses: Vec<(u16, String, String, &'static str)>,
    ) -> (Source, std::thread::JoinHandle<()>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = std::thread::spawn(move || {
            for (status, body, headers, expected) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut chunk = [0; 4096];
                loop {
                    let count = stream.read(&mut chunk).unwrap();
                    assert!(count > 0);
                    bytes.extend_from_slice(&chunk[..count]);
                    if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&bytes[..end]).to_lowercase();
                        let size = head
                            .lines()
                            .find_map(|s| s.strip_prefix("content-length: "))
                            .and_then(|s| s.parse::<usize>().ok())
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + size {
                            break;
                        }
                    }
                }
                assert!(String::from_utf8_lossy(&bytes).contains(expected));
                write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}", body.len()).unwrap();
            }
        });
        // Only the in-module HTTP fixture bypasses public HTTPS-only validation.
        let source = Source {
            config: UsageConfig {
                base_url: format!("http://{address}"),
                email: "test@example.com".into(),
                timezone: "Asia/Shanghai".into(),
            },
            password: "fixture-password".into(),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            access: String::new(),
            refresh: String::new(),
        };
        (source, handle)
    }
    #[tokio::test]
    async fn http_login_refresh_and_response_boundaries() {
        let tokens = json!({"code":0,"data":{"access_token":"fixture-access","refresh_token":"fixture-refresh"}}).to_string();
        let usage =
            json!({"code":0,"data":{"today_actual_cost":12.35,"today_tokens":1200000,"tpm":4500}})
                .to_string();
        let (mut source, server) = fixture(vec![
            (
                200,
                tokens.clone(),
                String::new(),
                "POST /api/v1/auth/login",
            ),
            (
                401,
                "{}".into(),
                String::new(),
                "authorization: Bearer fixture-access",
            ),
            (200, tokens, String::new(), "POST /api/v1/auth/refresh"),
            (
                200,
                usage,
                String::new(),
                "GET /api/v1/usage/dashboard/stats",
            ),
        ]);
        let value = source
            .fetch(1792123200)
            .await
            .unwrap_or_else(|_| panic!("fixture fetch failed"));
        assert_eq!(value.actual_cost_micros, 12_350_000);
        assert_eq!(value.token_count, 1_200_000);
        server.join().unwrap();

        let (mut source, server) = fixture(vec![(
            429,
            "{}".into(),
            "Retry-After: 123\r\n".into(),
            "POST /api/v1/auth/login",
        )]);
        assert!(
            matches!(source.fetch(1792123200).await,Err(Error::RateLimited(d)) if d == Duration::from_secs(123))
        );
        server.join().unwrap();
        let (mut source, server) = fixture(vec![(
            200,
            "x".repeat(8193),
            String::new(),
            "POST /api/v1/auth/login",
        )]);
        assert!(matches!(
            source.fetch(1792123200).await,
            Err(Error::Invalid)
        ));
        server.join().unwrap();
    }
    #[test]
    fn values_are_exact_bounded_and_have_local_day_window() {
        let now = chrono::DateTime::parse_from_rfc3339("2026-10-15T00:30:00+08:00")
            .unwrap()
            .timestamp() as u64;
        let v = parse_usage(
            &json!({"today_actual_cost":1.2345675,"today_tokens":0,"tpm":0}),
            "Asia/Shanghai",
            now,
        )
        .unwrap();
        assert_eq!(v.actual_cost_micros, 1_234_568);
        assert_eq!(v.window_end - v.window_start, 86400);
        assert_eq!(v.window_start, now - 1800);
        // DST is a calendar day, not always 86400 seconds.
        let dst = chrono::DateTime::parse_from_rfc3339("2026-03-08T12:00:00-04:00")
            .unwrap()
            .timestamp() as u64;
        let v = parse_usage(
            &json!({"today_actual_cost":0,"today_tokens":0,"tpm":0}),
            "America/New_York",
            dst,
        )
        .unwrap();
        assert_eq!(v.window_end - v.window_start, 23 * 3600);
        for v in [
            json!({}),
            json!({"today_actual_cost":-1,"today_tokens":0,"tpm":0}),
            json!({"today_actual_cost":1e20,"today_tokens":0,"tpm":0}),
            json!({"today_actual_cost":1,"today_tokens":1.2,"tpm":0}),
        ] {
            assert!(parse_usage(&v, "Asia/Shanghai", now).is_err());
        }
    }
    #[test]
    fn endpoint_rejects_credentials_and_insecure_transport() {
        let mut c = UsageConfig {
            base_url: "https://example.com".into(),
            email: "a@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        };
        c.validate().unwrap();
        assert_eq!(
            c.endpoint("auth/login"),
            "https://example.com/api/v1/auth/login"
        );
        for url in [
            "http://example.com",
            "https://user:pass@example.com",
            "https://example.com?token=secret",
            "https://example.com#x",
        ] {
            c.base_url = url.into();
            assert!(c.validate().is_err());
        }
    }
}
