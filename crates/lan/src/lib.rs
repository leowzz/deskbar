//! Embedded TLS listener and untrusted LAN discovery. No independent service.
pub mod icons;
mod usage;
use anyhow::{Context, Result};
use axum::{
    extract::{ws::Message, Path, State, WebSocketUpgrade},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_server::tls_rustls::RustlsConfig;
use base64::{engine::general_purpose::STANDARD, Engine};
use deskbar_host::{
    now,
    workbench::{Command, OpenTarget, Permissions, ShortcutConfig},
    Device, Host, PairingRequest,
};
use rcgen::{CertificateParams, KeyPair, PublicKeyData};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    net::{Ipv4Addr, SocketAddr, TcpListener},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::watch;

pub const DISCOVERY_GROUP: Ipv4Addr = Ipv4Addr::new(239, 77, 68, 76);
pub const PORT: u16 = 42831;

pub struct Identity {
    pub key_pem: String,
    pub cert_pem: String,
    pub pin: String,
}

impl Identity {
    pub fn load(host_id: &str) -> Result<Self> {
        let entry = keyring::Entry::new("app.deskbar.agent", host_id)?;
        let key_pem = match entry.get_password() {
            Ok(value) => value,
            Err(keyring::Error::NoEntry) => {
                let value = KeyPair::generate()?.serialize_pem();
                entry
                    .set_password(&value)
                    .context("无法保存电脑身份，请允许 DeskBar 连接助手访问系统钥匙串后重试")?;
                value
            }
            Err(e) => return Err(e).context("无法读取电脑身份，请解锁系统钥匙串后重试"),
        };
        Self::from_key(key_pem)
    }

    pub fn from_key(key_pem: String) -> Result<Self> {
        let key = KeyPair::from_pem(&key_pem)?;
        let pin = format!(
            "sha256/{}",
            STANDARD.encode(Sha256::digest(key.subject_public_key_info()))
        );
        let cert = CertificateParams::new(vec!["deskbar.local".into()])?.self_signed(&key)?;
        Ok(Self {
            key_pem,
            cert_pem: cert.pem(),
            pin,
        })
    }
}

#[derive(Clone)]
pub struct Agent {
    pub host: Arc<Mutex<Host>>,
    pub port: u16,
    pub pin: String,
    pub endpoints: Vec<String>,
    pub discovery_error: Option<String>,
    changed: watch::Sender<u64>,
    refresh: Arc<tokio::sync::Notify>,
    usage_refresh: Arc<tokio::sync::Notify>,
    usage_generation: Arc<std::sync::atomic::AtomicU64>,
}

#[derive(Serialize)]
pub struct AgentStatus {
    pub name: String,
    pub host_id: String,
    pub devices: Vec<Device>,
    pub pending: Option<PairingRequest>,
    pub addresses: Vec<String>,
    pub discovery_warning: Option<String>,
    pub workbench: deskbar_host::Snapshot,
    pub shortcuts: Vec<ShortcutConfig>,
    pub usage_config: Option<deskbar_host::usage::UsageConfig>,
}

#[derive(Serialize)]
pub struct PairingInvitation {
    pub uri: String,
    pub expires_at: u64,
}

impl Agent {
    pub async fn start(directory: PathBuf, name: String) -> Result<Self> {
        let host = Host::load(directory, name)
            .context("无法读取电脑配置，请检查是否已在运行或配置目录不可访问")?;
        let identity = Identity::load(&host.id)?;
        let agent = Self::with_identity(host, identity, PORT).await?;
        agent.start_sources();
        agent.start_usage();
        agent.start_shortcut_icons();
        Ok(agent)
    }

    pub async fn with_identity(
        host: Host,
        identity: Identity,
        preferred_port: u16,
    ) -> Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, preferred_port))
            .or_else(|_| TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)))
            .context("无法开启局域网连接，请检查本地网络权限")?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let config = RustlsConfig::from_pem(
            identity.cert_pem.into_bytes(),
            identity.key_pem.into_bytes(),
        )
        .await?;
        let (changed, _) = watch::channel(1);
        let mut agent = Self {
            host: Arc::new(Mutex::new(host)),
            port,
            pin: identity.pin,
            endpoints: addresses(port),
            discovery_error: None,
            changed,
            refresh: Arc::new(tokio::sync::Notify::new()),
            usage_refresh: Arc::new(tokio::sync::Notify::new()),
            usage_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        };
        // Discovery failure leaves the QR/manual invitation path usable.
        match discovery_socket() {
            Ok(socket) => {
                let state = agent.clone();
                tokio::spawn(async move {
                    discovery(socket, state).await;
                });
            }
            Err(_) => {
                agent.discovery_error = Some("自动发现暂不可用，仍可扫码或粘贴邀请连接。".into())
            }
        }
        let app = router(agent.clone());
        let server = axum_server::from_tcp_rustls(listener, config)?;
        tokio::spawn(async move {
            if let Err(error) = server
                .serve(app.into_make_service_with_connect_info::<SocketAddr>())
                .await
            {
                eprintln!("DeskBar TLS listener stopped: {error}");
                // A listener dying must not leave a healthy-looking background app.
                std::process::exit(1);
            }
        });
        Ok(agent)
    }

    pub fn status(&self) -> AgentStatus {
        let host = self.host.lock().unwrap();
        AgentStatus {
            name: host.name.clone(),
            host_id: host.id.clone(),
            devices: host.devices.clone(),
            pending: host.pending(now()),
            addresses: addresses(self.port),
            discovery_warning: self.discovery_error.clone(),
            workbench: host.snapshot(),
            shortcuts: host.shortcuts.clone(),
            usage_config: host.usage_config.clone(),
        }
    }

    fn start_sources(&self) {
        let agent = self.clone();
        tokio::spawn(async move {
            loop {
                let result = tokio::task::spawn_blocking(|| {
                    deskbar_host::sources::sessions(&deskbar_host::sources::codex_home())
                })
                .await;
                {
                    let mut host = agent.host.lock().unwrap();
                    let result =
                        result.unwrap_or_else(|_| Err(anyhow::anyhow!("无法读取 Codex 会话")));
                    let health = result
                        .map(|(sessions, total)| {
                            host.workbench.sessions = sessions;
                            host.workbench.session_total = total;
                        })
                        .map_err(|_| {
                            anyhow::anyhow!(
                                "无法读取 Codex 会话，请确认 Codex 已打开并更新连接助手"
                            )
                        });
                    host.workbench.observed("codex.sessions", health, now(), 20);
                    host.revision += 1;
                }
                agent.changed.send_modify(|r| *r += 1);
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        });
        let agent = self.clone();
        tokio::spawn(async move {
            loop {
                let result = deskbar_host::sources::quotas().await;
                {
                    let mut host = agent.host.lock().unwrap();
                    let health = result.map(|quotas| {
                        host.workbench.quotas = quotas;
                    });
                    host.workbench.observed("codex.quota", health, now(), 180);
                    host.revision += 1;
                }
                agent.changed.send_modify(|r| *r += 1);
                tokio::select! { _ = tokio::time::sleep(Duration::from_secs(120)) => {}, _ = agent.refresh.notified() => {} }
            }
        });
    }
    pub fn refresh_sources(&self) {
        self.refresh.notify_one();
        self.usage_refresh.notify_one();
    }
    pub fn save_layout(
        &self,
        id: &str,
        expected_revision: u64,
        layout: deskbar_host::layout::LayoutDocument,
    ) -> Result<u64> {
        let revision = self
            .host
            .lock()
            .unwrap()
            .save_layout(id, expected_revision, layout)?;
        self.changed.send_modify(|r| *r += 1);
        Ok(revision)
    }
    pub fn set_permissions(&self, id: &str, permissions: Permissions) -> Result<()> {
        self.host.lock().unwrap().set_permissions(id, permissions)?;
        self.changed.send_modify(|r| *r += 1);
        Ok(())
    }
    pub fn save_shortcut(&self, mut item: ShortcutConfig) -> Result<()> {
        item.validate()?;
        let automatic = item.icon_png.is_empty();
        if automatic {
            item.icon_png = icons::for_shortcut(&item).unwrap_or_default();
        }
        let mut host = self.host.lock().unwrap();
        if automatic {
            let previous_bytes = host
                .shortcuts
                .iter()
                .filter(|s| s.id != item.id)
                .filter_map(|s| STANDARD.decode(&s.icon_png).ok())
                .map(|v| v.len())
                .sum::<usize>();
            let new_bytes = STANDARD.decode(&item.icon_png).map_or(0, |v| v.len());
            if previous_bytes + new_bytes > deskbar_host::workbench::MAX_SHORTCUT_ICON_BYTES {
                item.icon_png.clear();
            }
        }
        host.save_shortcut(item)?;
        self.changed.send_modify(|r| *r += 1);
        Ok(())
    }
    fn start_shortcut_icons(&self) {
        let agent = self.clone();
        tokio::task::spawn_blocking(move || {
            let shortcuts = agent.host.lock().unwrap().shortcuts.clone();
            for item in shortcuts.into_iter().filter(|s| s.icon_png.is_empty()) {
                let Ok(icon) = icons::for_shortcut(&item) else {
                    continue;
                };
                if icon.is_empty() {
                    continue;
                }
                let mut host = agent.host.lock().unwrap();
                let Some(mut current) = host
                    .shortcuts
                    .iter()
                    .find(|s| {
                        s.id == item.id
                            && s.kind == item.kind
                            && s.target == item.target
                            && s.icon_png.is_empty()
                    })
                    .cloned()
                else {
                    continue;
                };
                current.icon_png = icon;
                // Running actions and the original entry survive any acquisition,
                // persistence or aggregate-budget failure.
                if host.save_shortcut(current).is_ok() {
                    agent.changed.send_modify(|r| *r += 1);
                }
            }
        });
    }

    pub fn remove_shortcut(&self, id: &str) -> Result<()> {
        self.host.lock().unwrap().remove_shortcut(id)?;
        self.changed.send_modify(|r| *r += 1);
        Ok(())
    }

    pub fn reorder_shortcuts(&self, ids: &[String]) -> Result<()> {
        self.host.lock().unwrap().reorder_shortcuts(ids)?;
        self.changed.send_modify(|r| *r += 1);
        Ok(())
    }

    pub fn invite(&self) -> Result<PairingInvitation> {
        let endpoints = addresses(self.port);
        anyhow::ensure!(
            !endpoints.is_empty(),
            "还没有可用的局域网，请连接 Wi-Fi 或网线后重试"
        );
        let mut host = self.host.lock().unwrap();
        let invite = host.invite(now());
        let mut uri = url::Url::parse("deskbar://pair")?;
        uri.query_pairs_mut()
            .append_pair("v", "1")
            .append_pair("host", &host.id)
            .append_pair("name", &host.name)
            .append_pair("pin", &self.pin)
            .append_pair("session", &invite.session_id)
            .append_pair("secret", &invite.secret)
            .append_pair("expires", &invite.expires_at.to_string());
        for endpoint in endpoints {
            uri.query_pairs_mut().append_pair("endpoint", &endpoint);
        }
        Ok(PairingInvitation {
            uri: uri.into(),
            expires_at: invite.expires_at,
        })
    }

    pub fn approve(&self, id: &str) -> Result<()> {
        self.host.lock().unwrap().approve(id, now())?;
        self.changed.send_modify(|revision| *revision += 1);
        Ok(())
    }

    pub fn cancel_pairing(&self) {
        self.host.lock().unwrap().cancel_pairing();
    }

    pub fn revoke(&self, id: &str) -> Result<()> {
        self.host.lock().unwrap().revoke(id)?;
        self.changed.send_modify(|revision| *revision += 1);
        Ok(())
    }
}

fn addresses(port: u16) -> Vec<String> {
    let mut addresses: Vec<_> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|i| match i.ip() {
            std::net::IpAddr::V4(ip) if !ip.is_loopback() && !ip.is_link_local() => {
                Some(format!("https://{ip}:{port}"))
            }
            _ => None,
        })
        .collect();
    addresses.sort();
    addresses.dedup();
    addresses
}

fn router(agent: Agent) -> Router {
    Router::new()
        .route("/v1/pairing/request", post(request_pairing))
        .route("/v1/pairing/status", post(claim_pairing))
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/events", get(events))
        .route("/v1/commands", post(command))
        .route("/v1/commands/{id}", get(command_result))
        .layer(axum::extract::DefaultBodyLimit::max(4096))
        .with_state(agent)
}

#[derive(Deserialize)]
struct PairInput {
    session_id: String,
    secret: String,
    claim: String,
    name: String,
}
#[derive(Deserialize)]
struct ClaimInput {
    request_id: String,
    claim: String,
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(serde_json::json!({"message":message}))).into_response()
}

async fn request_pairing(State(agent): State<Agent>, Json(input): Json<PairInput>) -> Response {
    match agent.host.lock().unwrap().request_pairing(
        &input.session_id,
        &input.secret,
        &input.claim,
        &input.name,
        now(),
    ) {
        Ok(value) => Json(value).into_response(),
        Err(e) => error(StatusCode::BAD_REQUEST, &e.to_string()),
    }
}

async fn claim_pairing(State(agent): State<Agent>, Json(input): Json<ClaimInput>) -> Response {
    match agent
        .host
        .lock()
        .unwrap()
        .claim(&input.request_id, &input.claim, now())
    {
        Ok(token) => Json(serde_json::json!({"token":token})).into_response(),
        Err(e) => error(StatusCode::GONE, &e.to_string()),
    }
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("authorization")?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

async fn snapshot(State(agent): State<Agent>, headers: HeaderMap) -> Response {
    let host = agent.host.lock().unwrap();
    if !bearer(&headers).is_some_and(|token| host.authenticate(token)) {
        return error(StatusCode::UNAUTHORIZED, "这台设备已取消连接，请重新配对");
    }
    Json(host.authorized_snapshot(bearer(&headers).unwrap()).unwrap()).into_response()
}

async fn events(State(agent): State<Agent>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    let Some(token) = bearer(&headers)
        .filter(|token| agent.host.lock().unwrap().authenticate(token))
        .map(str::to_owned)
    else {
        return error(StatusCode::UNAUTHORIZED, "这台设备已取消连接，请重新配对");
    };
    // Subscribe before reading the initial snapshot so no update is lost.
    let mut changes = agent.changed.subscribe();
    ws.max_message_size(2048).max_frame_size(2048).on_upgrade(move |mut socket| async move {
        let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
        loop {
            let json = {
                let host = agent.host.lock().unwrap();
                host.authorized_snapshot(&token).map(|snapshot| serde_json::to_string(&snapshot).unwrap())
            };
            let Some(json) = json else {
                let _ = socket.send(Message::Text("{\"type\":\"revoked\"}".into())).await;
                let _ = socket.send(Message::Close(None)).await;
                break;
            };
            if socket.send(Message::Text(json.into())).await.is_err() { break; }
            tokio::select! {
                _ = changes.changed() => {},
                _ = heartbeat.tick() => {},
                message = socket.recv() => { match message {
                    Some(Ok(Message::Ping(bytes))) => { if socket.send(Message::Pong(bytes)).await.is_err() { break; } },
                    Some(Ok(Message::Pong(_))) => {},
                    Some(Ok(Message::Text(text))) if text.len() <= 2048 => {
                        if let Ok(report) = serde_json::from_str::<deskbar_host::layout::DisplayReport>(&text) {
                            let _ = agent.host.lock().unwrap().report_display(&token, report);
                        }
                    },
                    _ => break,
                } },
            }
        }
    }).into_response()
}

async fn command(
    State(agent): State<Agent>,
    headers: HeaderMap,
    Json(input): Json<Command>,
) -> Response {
    let prepared = {
        let mut host = agent.host.lock().unwrap();
        let Some(device) = bearer(&headers).and_then(|t| host.device_id(t)) else {
            return error(StatusCode::UNAUTHORIZED, "这台设备已取消连接，请重新配对");
        };
        host.prepare_command(&device, input, now())
            .map(|(result, target)| (device, result, target))
    };
    match prepared {
        Err(e) => error(StatusCode::BAD_REQUEST, &e.to_string()),
        Ok((device, result, target)) => {
            if let Some(target) = target {
                let id = result.command_id.clone();
                tokio::spawn(async move {
                    let outcome = open_target(target).await;
                    let (status, message) = match outcome {
                        Some(true) => ("succeeded", "电脑已接受打开请求"),
                        Some(false) => ("failed", "未能打开，请检查电脑上的应用或入口设置"),
                        None => ("unknown", "打开请求超时，结果未知；请先查看电脑"),
                    };
                    agent
                        .host
                        .lock()
                        .unwrap()
                        .finish_command(&device, &id, status, message);
                });
            }
            Json(result).into_response()
        }
    }
}
async fn command_result(
    State(agent): State<Agent>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let host = agent.host.lock().unwrap();
    let Some(device) = bearer(&headers).and_then(|t| host.device_id(t)) else {
        return error(StatusCode::UNAUTHORIZED, "这台设备已取消连接，请重新配对");
    };
    Json(host.command_result(&device, &id)).into_response()
}
async fn open_target(target: OpenTarget) -> Option<bool> {
    let target = match target {
        OpenTarget::Session(id) => format!("codex://threads/{id}"),
        OpenTarget::Shortcut(item) => item.target,
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        for command in open::commands(target) {
            let mut command = tokio::process::Command::from(command);
            command
                .kill_on_drop(true)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            if command.status().await.is_ok_and(|s| s.success()) {
                return true;
            }
        }
        false
    })
    .await
    .ok()
}

fn discovery_socket() -> Result<tokio::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    socket.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, PORT)).into())?;
    let mut joined = false;
    for iface in if_addrs::get_if_addrs()? {
        if let std::net::IpAddr::V4(ip) = iface.ip() {
            if !ip.is_loopback() && socket.join_multicast_v4(&DISCOVERY_GROUP, &ip).is_ok() {
                joined = true;
            }
        }
    }
    anyhow::ensure!(joined, "No multicast interface");
    socket.set_multicast_ttl_v4(1)?;
    socket.set_nonblocking(true)?;
    Ok(tokio::net::UdpSocket::from_std(socket.into())?)
}

async fn discovery(socket: tokio::net::UdpSocket, agent: Agent) {
    let mut bytes = [0; 2048];
    let mut last = std::collections::HashMap::new();
    loop {
        let Ok((length, source)) = socket.recv_from(&mut bytes).await else {
            break;
        };
        let Ok(query) = serde_json::from_slice::<serde_json::Value>(&bytes[..length]) else {
            continue;
        };
        if query["product"] != "deskbar" || query["version"] != 1 || query["type"] != "query" {
            continue;
        }
        let Some(nonce) = query["nonce"]
            .as_str()
            .filter(|n| n.len() >= 16 && n.len() <= 64)
        else {
            continue;
        };
        let instant = Instant::now();
        last.retain(|_, time: &mut Instant| instant.duration_since(*time) < Duration::from_secs(2));
        if last.contains_key(&source.ip()) || last.len() >= 128 {
            continue;
        }
        last.insert(source.ip(), instant);
        let offer = {
            let host = agent.host.lock().unwrap();
            serde_json::json!({"product":"deskbar", "version":1, "type":"offer", "nonce":nonce,
                "host_id":host.id, "name":host.name, "port":agent.port, "pin":agent.pin})
        };
        let _ = socket
            .send_to(&serde_json::to_vec(&offer).unwrap(), source)
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn real_tls_requires_approval_and_revocation_is_immediate() {
        let dir = tempfile::tempdir().unwrap();
        let host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let identity = Identity::from_key(KeyPair::generate().unwrap().serialize_pem()).unwrap();
        let cert = reqwest::Certificate::from_pem(identity.cert_pem.as_bytes()).unwrap();
        use rustls::pki_types::pem::PemObject;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(
                rustls::pki_types::CertificateDer::from_pem_slice(identity.cert_pem.as_bytes())
                    .unwrap(),
            )
            .unwrap();
        let tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let agent = Agent::with_identity(host, identity, 0).await.unwrap();
        let client = reqwest::Client::builder()
            .add_root_certificate(cert)
            .resolve(
                "deskbar.local",
                SocketAddr::from(([127, 0, 0, 1], agent.port)),
            )
            .no_proxy()
            .build()
            .unwrap();
        let base = format!("https://deskbar.local:{}", agent.port);
        assert_eq!(
            client
                .get(format!("{base}/v1/snapshot"))
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        let invite = agent.host.lock().unwrap().invite(now());
        let claim = deskbar_host::secret();
        let pending: serde_json::Value = client.post(format!("{base}/v1/pairing/request")).json(&serde_json::json!({"session_id":invite.session_id,"secret":invite.secret,"claim":claim,"name":"屏幕"})).send().await.unwrap().json().await.unwrap();
        let id = pending["id"].as_str().unwrap();
        agent.approve(id).unwrap();
        let response: serde_json::Value = client
            .post(format!("{base}/v1/pairing/status"))
            .json(&serde_json::json!({"request_id":id,"claim":claim}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let token = response["token"].as_str().unwrap();
        let snapshot: deskbar_host::Snapshot = client
            .get(format!("{base}/v1/snapshot"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(snapshot.host_id, agent.status().host_id);
        assert!(snapshot.capabilities.is_empty());
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message as WsMessage};
        let mut request = format!("wss://deskbar.local:{}/v1/events", agent.port)
            .into_client_request()
            .unwrap();
        request
            .headers_mut()
            .insert("authorization", format!("Bearer {token}").parse().unwrap());
        let tcp = tokio::net::TcpStream::connect(("127.0.0.1", agent.port))
            .await
            .unwrap();
        let (mut socket, _) = tokio_tungstenite::client_async_tls_with_config(
            request,
            tcp,
            None,
            Some(tokio_tungstenite::Connector::Rustls(Arc::new(tls))),
        )
        .await
        .unwrap();
        let display = serde_json::json!({"width":1280.0,"height":720.0,"text_scale":1.0,"dark":false,"page_id":"main","layout_revision":0});
        socket
            .send(WsMessage::Text(display.to_string().into()))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                socket.next().await.unwrap().unwrap();
                if agent.status().devices[0].display.is_some() {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let layout =
            serde_json::from_str(include_str!("../../../protocol/layout.example.json")).unwrap();
        agent.save_layout(id, 0, layout).unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let message = socket.next().await.unwrap().unwrap();
                let next: deskbar_host::Snapshot =
                    serde_json::from_str(message.to_text().unwrap()).unwrap();
                if next.layout_revision == 1 {
                    assert_eq!(next.layout.unwrap().pages[0].name, "工作台");
                    break;
                }
            }
        })
        .await
        .unwrap();
        agent.revoke(id).unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let message = socket.next().await.unwrap().unwrap();
                if message.to_text().unwrap().contains("revoked") {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(
            client
                .get(format!("{base}/v1/snapshot"))
                .bearer_auth(token)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }

    #[test]
    fn renewing_certificate_preserves_key_pin() {
        let key = KeyPair::generate().unwrap().serialize_pem();
        assert_eq!(
            Identity::from_key(key.clone()).unwrap().pin,
            Identity::from_key(key).unwrap().pin
        );
        assert_ne!(
            Identity::from_key(KeyPair::generate().unwrap().serialize_pem())
                .unwrap()
                .pin,
            Identity::from_key(KeyPair::generate().unwrap().serialize_pem())
                .unwrap()
                .pin
        );
    }
}
