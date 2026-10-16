//! Embedded TLS listener and untrusted LAN discovery. No independent service.
use anyhow::{Context, Result};
use axum::{
    extract::{ws::Message, State, WebSocketUpgrade},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_server::tls_rustls::RustlsConfig;
use base64::{engine::general_purpose::STANDARD, Engine};
use desklet_host::{now, Device, Host, PairingRequest};
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
        let entry = keyring::Entry::new("app.desklet.agent", host_id)?;
        let key_pem = match entry.get_password() {
            Ok(value) => value,
            Err(keyring::Error::NoEntry) => {
                let value = KeyPair::generate()?.serialize_pem();
                entry
                    .set_password(&value)
                    .context("无法保存电脑身份，请允许 Desklet 连接助手访问系统钥匙串后重试")?;
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
        let cert = CertificateParams::new(vec!["desklet.local".into()])?.self_signed(&key)?;
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
}

#[derive(Serialize)]
pub struct AgentStatus {
    pub name: String,
    pub host_id: String,
    pub devices: Vec<Device>,
    pub pending: Option<PairingRequest>,
    pub addresses: Vec<String>,
    pub discovery_warning: Option<String>,
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
        Self::with_identity(host, identity, PORT).await
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
                eprintln!("Desklet TLS listener stopped: {error}");
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
        }
    }

    pub fn invite(&self) -> Result<PairingInvitation> {
        let endpoints = addresses(self.port);
        anyhow::ensure!(
            !endpoints.is_empty(),
            "还没有可用的局域网，请连接 Wi-Fi 或网线后重试"
        );
        let mut host = self.host.lock().unwrap();
        let invite = host.invite(now());
        let mut uri = url::Url::parse("desklet://pair")?;
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
    Json(host.snapshot()).into_response()
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
    ws.on_upgrade(move |mut socket| async move {
        let mut heartbeat = tokio::time::interval(Duration::from_secs(10));
        loop {
            let json = {
                let host = agent.host.lock().unwrap();
                if !host.authenticate(&token) { None } else { Some(serde_json::to_string(&host.snapshot()).unwrap()) }
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
                    _ => break,
                } },
            }
        }
    }).into_response()
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
        if query["product"] != "desklet" || query["version"] != 1 || query["type"] != "query" {
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
            serde_json::json!({"product":"desklet", "version":1, "type":"offer", "nonce":nonce,
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
        let agent = Agent::with_identity(host, identity, 0).await.unwrap();
        let client = reqwest::Client::builder()
            .add_root_certificate(cert)
            .resolve(
                "desklet.local",
                SocketAddr::from(([127, 0, 0, 1], agent.port)),
            )
            .no_proxy()
            .build()
            .unwrap();
        let base = format!("https://desklet.local:{}", agent.port);
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
        let claim = desklet_host::secret();
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
        let snapshot: desklet_host::Snapshot = client
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
        agent.revoke(id).unwrap();
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
