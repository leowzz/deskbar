//! Host identity, device approval, authorized state and independent source adapters.
pub mod layout;
pub mod sources;
pub mod usage;
pub mod workbench;
use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use uuid::Uuid;
use workbench::*;

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn secret() -> String {
    let mut bytes = [0; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn digest(value: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(value.as_bytes()))
}
fn matches(a: &str, b: &str) -> bool {
    bool::from(a.as_bytes().ct_eq(b.as_bytes()))
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub paired_at: u64,
    #[serde(default)]
    pub permissions: Permissions,
    #[serde(default)]
    pub layout: Option<layout::LayoutDocument>,
    #[serde(default)]
    pub layout_revision: u64,
    #[serde(skip_deserializing)]
    pub display: Option<layout::DisplayState>,
    #[serde(skip_serializing, default)]
    pub token_hash: String,
}

// Separate disk record so serializing a UI response can never expose token hashes.
#[derive(Serialize, Deserialize)]
struct StoredDevice {
    id: String,
    name: String,
    paired_at: u64,
    token_hash: String,
    #[serde(default)]
    permissions: Permissions,
    #[serde(default)]
    layout: Option<layout::LayoutDocument>,
    #[serde(default)]
    layout_revision: u64,
}

#[derive(Serialize, Deserialize)]
struct Settings {
    host_id: String,
    name: String,
    devices: Vec<StoredDevice>,
    #[serde(default)]
    shortcuts: Vec<ShortcutConfig>,
    #[serde(default)]
    usage_config: Option<usage::UsageConfig>,
}

#[derive(Clone, Serialize)]
pub struct Invitation {
    pub session_id: String,
    pub secret: String,
    pub expires_at: u64,
}

#[derive(Clone, Serialize)]
pub struct PairingRequest {
    pub id: String,
    pub name: String,
    pub expires_at: u64,
}

struct Pending {
    info: PairingRequest,
    session_id: String,
    invitation_hash: String,
    claim_hash: String,
    token: String,
    approved: bool,
}

pub struct Host {
    pub id: String,
    pub name: String,
    pub epoch: String,
    pub revision: u64,
    pub devices: Vec<Device>,
    pub workbench: Workbench,
    pub shortcuts: Vec<ShortcutConfig>,
    pub usage_config: Option<usage::UsageConfig>,
    commands: std::collections::HashMap<(String, String), (Command, CommandResult)>,
    path: PathBuf,
    invitation: Option<Invitation>,
    pending: Option<Pending>,
    _lock: fs::File,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub protocol_version: u32,
    pub host_id: String,
    pub name: String,
    pub epoch: String,
    pub revision: u64,
    pub server_time: u64,
    pub sources: Vec<SourceState>,
    #[serde(default)]
    pub sessions: Vec<Session>,
    #[serde(default)]
    pub session_total: usize,
    #[serde(default)]
    pub quotas: Vec<Quota>,
    #[serde(default)]
    pub api_usage: Vec<ApiUsage>,
    #[serde(default)]
    pub shortcuts: Vec<Shortcut>,
    pub capabilities: Vec<String>,
    pub layout: Option<layout::LayoutDocument>,
    pub layout_revision: u64,
}

impl Host {
    pub fn load(directory: PathBuf, default_name: String) -> Result<Self> {
        fs::create_dir_all(&directory)?;
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("agent.lock"))?;
        lock.try_lock()
            .context("DeskBar 连接助手已在运行，请从菜单栏打开")?;
        let path = directory.join("host.yaml");
        let settings: Settings = if path.exists() {
            serde_yaml::from_str(&fs::read_to_string(&path)?)
                .context("电脑配置无法读取，请保留文件并重试")?
        } else {
            Settings {
                host_id: Uuid::new_v4().to_string(),
                name: default_name,
                devices: vec![],
                shortcuts: vec![],
                usage_config: None,
            }
        };
        let mut shortcuts = settings.shortcuts;
        workbench::sanitize_shortcut_icons(&mut shortcuts);
        let host = Self {
            id: settings.host_id,
            name: settings.name,
            epoch: Uuid::new_v4().to_string(),
            revision: 1,
            devices: settings
                .devices
                .into_iter()
                .map(|d| Device {
                    id: d.id,
                    name: d.name,
                    paired_at: d.paired_at,
                    token_hash: d.token_hash,
                    permissions: d.permissions,
                    layout: d.layout,
                    layout_revision: d.layout_revision,
                    display: None,
                })
                .collect(),
            workbench: Workbench::default(),
            shortcuts,
            usage_config: settings.usage_config,
            commands: Default::default(),
            path,
            invitation: None,
            pending: None,
            _lock: lock,
        };
        host.save(&host.devices)?;
        Ok(host)
    }

    fn save(&self, devices: &[Device]) -> Result<()> {
        let settings = Settings {
            host_id: self.id.clone(),
            name: self.name.clone(),
            shortcuts: self.shortcuts.clone(),
            usage_config: self.usage_config.clone(),
            devices: devices
                .iter()
                .map(|d| StoredDevice {
                    id: d.id.clone(),
                    name: d.name.clone(),
                    paired_at: d.paired_at,
                    token_hash: d.token_hash.clone(),
                    permissions: d.permissions.clone(),
                    layout: d.layout.clone(),
                    layout_revision: d.layout_revision,
                })
                .collect(),
        };
        let temp = self.path.with_extension("yaml.tmp");
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        use std::io::Write;
        let mut file = options.open(&temp)?;
        file.write_all(serde_yaml::to_string(&settings)?.as_bytes())?;
        file.sync_all()?;
        fs::rename(temp, &self.path)?;
        Ok(())
    }

    pub fn invite(&mut self, time: u64) -> Invitation {
        self.pending = None;
        let invitation = Invitation {
            session_id: Uuid::new_v4().to_string(),
            secret: secret(),
            expires_at: time + 120,
        };
        self.invitation = Some(invitation.clone());
        invitation
    }

    pub fn cancel_pairing(&mut self) {
        self.invitation = None;
        self.pending = None;
    }

    pub fn request_pairing(
        &mut self,
        session: &str,
        password: &str,
        claim: &str,
        name: &str,
        time: u64,
    ) -> Result<PairingRequest> {
        // Recover a lost response without creating a second device.
        if let Some(p) = &self.pending {
            if time < p.info.expires_at
                && session == p.session_id
                && name.trim() == p.info.name
                && matches(&digest(password), &p.invitation_hash)
                && matches(&digest(claim), &p.claim_hash)
            {
                return Ok(p.info.clone());
            }
        }
        let invitation = self
            .invitation
            .as_ref()
            .context("邀请已失效，请在电脑上重新生成")?;
        if time >= invitation.expires_at
            || session != invitation.session_id
            || !matches(password, &invitation.secret)
        {
            bail!("邀请已失效，请在电脑上重新生成");
        }
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 64 || claim.len() != 43 {
            bail!("设备信息不完整");
        }
        let info = PairingRequest {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            expires_at: invitation.expires_at,
        };
        self.pending = Some(Pending {
            info: info.clone(),
            session_id: session.into(),
            invitation_hash: digest(password),
            claim_hash: digest(claim),
            token: secret(),
            approved: false,
        });
        self.invitation = None; // One invitation can request approval only once.
        Ok(info)
    }

    pub fn pending(&self, time: u64) -> Option<PairingRequest> {
        self.pending
            .as_ref()
            .filter(|p| !p.approved && time < p.info.expires_at)
            .map(|p| p.info.clone())
    }

    pub fn approve(&mut self, id: &str, time: u64) -> Result<()> {
        let p = self
            .pending
            .as_ref()
            .filter(|p| p.info.id == id && !p.approved && time < p.info.expires_at)
            .context("这次连接请求已结束")?;
        let mut devices = self.devices.clone();
        devices.push(Device {
            id: p.info.id.clone(),
            name: p.info.name.clone(),
            paired_at: time,
            token_hash: digest(&p.token),
            permissions: Permissions::default(),
            layout: None,
            layout_revision: 0,
            display: None,
        });
        self.save(&devices)?;
        self.devices = devices;
        self.pending.as_mut().unwrap().approved = true;
        self.revision += 1;
        Ok(())
    }

    pub fn claim(&self, id: &str, claim: &str, time: u64) -> Result<Option<String>> {
        let p = self
            .pending
            .as_ref()
            .filter(|p| {
                p.info.id == id
                    && time < p.info.expires_at
                    && matches(&p.claim_hash, &digest(claim))
            })
            .context("连接请求已失效，请重新连接")?;
        Ok(p.approved.then(|| p.token.clone()))
    }

    pub fn authenticate(&self, token: &str) -> bool {
        let hash = digest(token);
        self.devices.iter().any(|d| matches(&d.token_hash, &hash))
    }

    pub fn revoke(&mut self, id: &str) -> Result<()> {
        let devices: Vec<_> = self
            .devices
            .iter()
            .filter(|d| d.id != id)
            .cloned()
            .collect();
        if devices.len() == self.devices.len() {
            bail!("设备已移除");
        }
        self.save(&devices)?;
        self.devices = devices;
        if self.pending.as_ref().is_some_and(|p| p.info.id == id) {
            self.pending = None;
        }
        self.revision += 1;
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            protocol_version: 1,
            host_id: self.id.clone(),
            name: self.name.clone(),
            epoch: self.epoch.clone(),
            revision: self.revision,
            server_time: now(),
            sources: self.workbench.sources.clone(),
            sessions: self.workbench.sessions.clone(),
            session_total: self.workbench.session_total,
            quotas: self.workbench.quotas.clone(),
            api_usage: self.workbench.api_usage.clone(),
            shortcuts: self.shortcuts.iter().map(ShortcutConfig::public).collect(),
            capabilities: vec![],
            layout: None,
            layout_revision: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn approval_expiry_revocation_and_restart() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let invite = host.invite(100);
        assert!(host
            .request_pairing(&invite.session_id, "wrong", &secret(), "屏幕", 101)
            .is_err());
        let claim = secret();
        let p = host
            .request_pairing(&invite.session_id, &invite.secret, &claim, "屏幕", 101)
            .unwrap();
        assert!(host.claim(&p.id, &claim, 101).unwrap().is_none());
        assert!(host.claim(&p.id, &secret(), 101).is_err());
        assert_eq!(
            host.request_pairing(&invite.session_id, &invite.secret, &claim, "屏幕", 102)
                .unwrap()
                .id,
            p.id
        );
        assert!(host
            .request_pairing(&invite.session_id, &invite.secret, &secret(), "屏幕", 102)
            .is_err());
        host.approve(&p.id, 102).unwrap();
        let token = host.claim(&p.id, &claim, 103).unwrap().unwrap();
        assert!(host.authenticate(&token));
        assert!(!serde_json::to_string(&host.devices)
            .unwrap()
            .contains("token_hash"));
        assert!(!fs::read_to_string(dir.path().join("host.yaml"))
            .unwrap()
            .contains(&token));
        assert!(host.claim(&p.id, &claim, 220).is_err());
        let id = host.id.clone();
        let epoch = host.epoch.clone();
        assert!(Host::load(dir.path().into(), "unused".into()).is_err());
        drop(host);
        let mut restarted = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(restarted.id, id);
        assert_ne!(restarted.epoch, epoch);
        assert!(restarted.authenticate(&token));
        restarted.revoke(&p.id).unwrap();
        assert!(!restarted.authenticate(&token));
        drop(restarted);
        assert!(!Host::load(dir.path().into(), "unused".into())
            .unwrap()
            .authenticate(&token));
    }

    #[test]
    fn expired_or_replaced_invitation_never_grants_access() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let old = host.invite(100);
        assert!(host
            .request_pairing(&old.session_id, &old.secret, &secret(), "屏幕", 220)
            .is_err());
        host.invite(221);
        assert!(host
            .request_pairing(&old.session_id, &old.secret, &secret(), "屏幕", 222)
            .is_err());
        host.cancel_pairing();
        assert!(host.pending(222).is_none());
    }
}
