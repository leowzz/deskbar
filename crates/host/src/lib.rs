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

fn identity_digest(identity: &str) -> Result<String> {
    if identity.len() != 43
        || URL_SAFE_NO_PAD
            .decode(identity)
            .map_or(true, |bytes| bytes.len() != 32)
    {
        bail!("设备身份无效，请更新工作台后重试");
    }
    Ok(digest(identity))
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
    #[serde(skip)]
    pub identity_hash: Option<String>,
}

// Separate disk record so serializing a UI response can never expose token hashes.
#[derive(Serialize, Deserialize)]
struct StoredDevice {
    id: String,
    name: String,
    paired_at: u64,
    token_hash: String,
    #[serde(default)]
    identity_hash: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub existing_device_name: Option<String>,
}

struct Pending {
    info: PairingRequest,
    session_id: String,
    invitation_hash: String,
    claim_hash: String,
    token: String,
    approved: bool,
    identity_hash: Option<String>,
    device_id: String,
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
    completed_claims: std::collections::HashMap<(String, String), (String, u64)>,
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
    pub fn data_directory(&self) -> &std::path::Path {
        self.path
            .parent()
            .expect("host configuration has a directory")
    }

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
                    identity_hash: d.identity_hash,
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
            completed_claims: Default::default(),
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
                    identity_hash: d.identity_hash.clone(),
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

    /// Return the invitation used by automatic LAN discovery.
    ///
    /// Discovery can run repeatedly while the app is open, so it must reuse a
    /// still-valid invitation instead of invalidating a request that is already
    /// waiting for approval. Once the invitation expires, create a fresh one.
    pub fn discovery_invitation(&mut self, time: u64) -> Option<Invitation> {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| time < pending.info.expires_at)
        {
            return None;
        }
        // A client may disappear after requesting approval. Do not let its
        // expired one-time request block discovery indefinitely.
        self.pending = None;
        if let Some(invitation) = &self.invitation {
            if time < invitation.expires_at {
                return Some(invitation.clone());
            }
        }
        Some(self.invite(time))
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
        self.request_pairing_with_identity(session, password, claim, name, None, time)
    }

    pub fn request_pairing_with_identity(
        &mut self,
        session: &str,
        password: &str,
        claim: &str,
        name: &str,
        identity: Option<&str>,
        time: u64,
    ) -> Result<PairingRequest> {
        let identity_hash = identity.map(identity_digest).transpose()?;
        // Recover a lost response without creating a second device.
        if let Some(p) = &self.pending {
            if time < p.info.expires_at
                && session == p.session_id
                && name.trim() == p.info.name
                && identity_hash == p.identity_hash
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
        let existing = identity_hash.as_ref().and_then(|hash| {
            self.devices
                .iter()
                .find(|device| device.identity_hash.as_ref() == Some(hash))
        });
        let info = PairingRequest {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            expires_at: invitation.expires_at,
            existing_device_name: existing.map(|device| device.name.clone()),
        };
        let device_id = existing.map_or_else(|| info.id.clone(), |device| device.id.clone());
        self.pending = Some(Pending {
            info: info.clone(),
            session_id: session.into(),
            invitation_hash: digest(password),
            claim_hash: digest(claim),
            token: secret(),
            approved: false,
            identity_hash,
            device_id,
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
        if let Some(device) = devices.iter_mut().find(|device| device.id == p.device_id) {
            device.token_hash = digest(&p.token);
        } else {
            devices.push(Device {
                id: p.device_id.clone(),
                name: p.info.name.clone(),
                paired_at: time,
                token_hash: digest(&p.token),
                identity_hash: p.identity_hash.clone(),
                permissions: Permissions::default(),
                layout: None,
                layout_revision: 0,
                display: None,
            });
        }
        self.save(&devices)?;
        self.devices = devices;
        self.completed_claims.retain(|_, (token, _)| {
            self.devices
                .iter()
                .any(|device| matches(&device.token_hash, &digest(token)))
        });
        self.pending.as_mut().unwrap().approved = true;
        self.revision += 1;
        Ok(())
    }

    pub fn claim(&mut self, id: &str, claim: &str, time: u64) -> Result<Option<String>> {
        let key = (id.to_owned(), digest(claim));
        if let Some((token, expires_at)) = self.completed_claims.get(&key) {
            if time < *expires_at {
                return Ok(Some(token.clone()));
            }
        }
        self.completed_claims
            .retain(|_, (_, expires_at)| time < *expires_at);
        let (approved, token, expires_at) = {
            let p = self
                .pending
                .as_ref()
                .filter(|p| {
                    p.info.id == id
                        && time < p.info.expires_at
                        && matches(&p.claim_hash, &digest(claim))
                })
                .context("连接请求已失效，请重新连接")?;
            (p.approved, p.token.clone(), p.info.expires_at)
        };
        if !approved {
            return Ok(None);
        }
        self.completed_claims
            .insert(key, (token.clone(), expires_at));
        self.pending = None;
        Ok(Some(token))
    }

    pub fn authenticate(&self, token: &str) -> bool {
        let hash = digest(token);
        self.devices.iter().any(|d| matches(&d.token_hash, &hash))
    }

    pub fn register_device_identity(&mut self, token: &str, identity: &str) -> Result<()> {
        let hash = identity_digest(identity)?;
        let id = self
            .device_id(token)
            .context("这台设备已取消连接，请重新配对")?;
        let device = self.devices.iter().find(|device| device.id == id).unwrap();
        if let Some(existing) = &device.identity_hash {
            if existing != &hash {
                bail!("设备身份不一致，请重新配对");
            }
            return Ok(());
        }
        if self
            .devices
            .iter()
            .any(|device| device.identity_hash.as_ref() == Some(&hash))
        {
            bail!("设备身份已关联其他记录，请重新配对");
        }
        let mut devices = self.devices.clone();
        devices
            .iter_mut()
            .find(|device| device.id == id)
            .unwrap()
            .identity_hash = Some(hash);
        self.save(&devices)?;
        self.devices = devices;
        Ok(())
    }

    pub fn rename_device(&mut self, id: &str, name: &str) -> Result<()> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 64 || name.chars().any(char::is_control) {
            bail!("设备名称需为 1–64 个字符，且不能包含控制字符");
        }
        let mut devices = self.devices.clone();
        devices
            .iter_mut()
            .find(|device| device.id == id)
            .context("设备已移除")?
            .name = name.to_owned();
        self.save(&devices)?;
        self.devices = devices;
        self.revision += 1;
        Ok(())
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
        if self.pending.as_ref().is_some_and(|p| p.device_id == id) {
            self.pending = None;
        }
        self.completed_claims.retain(|_, (token, _)| {
            self.devices
                .iter()
                .any(|device| matches(&device.token_hash, &digest(token)))
        });
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
    fn pair_with_identity(host: &mut Host, identity: Option<&str>) -> (String, String) {
        let invite = host.invite(100);
        let claim = secret();
        let request = host
            .request_pairing_with_identity(
                &invite.session_id,
                &invite.secret,
                &claim,
                "同型号设备",
                identity,
                101,
            )
            .unwrap();
        host.approve(&request.id, 102).unwrap();
        let token = host.claim(&request.id, &claim, 103).unwrap().unwrap();
        (host.device_id(&token).unwrap(), token)
    }

    #[test]
    fn remembered_device_reuses_configuration_after_restart_and_rotates_token() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let identity = secret();
        let (id, old_token) = pair_with_identity(&mut host, Some(&identity));
        host.rename_device(&id, "桌面副屏").unwrap();
        host.set_permissions(
            &id,
            Permissions {
                sessions: true,
                quota: true,
                api_usage: true,
                shortcuts: true,
                open: true,
            },
        )
        .unwrap();
        let layout =
            serde_json::from_str(include_str!("../../../protocol/layout.example.json")).unwrap();
        host.save_layout(&id, 0, layout).unwrap();
        let original = serde_json::to_value(&host.devices[0]).unwrap();
        assert!(original.get("identity_hash").is_none());
        assert!(!fs::read_to_string(dir.path().join("host.yaml"))
            .unwrap()
            .contains(&identity));
        drop(host);
        let mut host = Host::load(dir.path().into(), "unused".into()).unwrap();
        let invite = host.invite(200);
        let claim = secret();
        let request = host
            .request_pairing_with_identity(
                &invite.session_id,
                &invite.secret,
                &claim,
                "新的型号名",
                Some(&identity),
                201,
            )
            .unwrap();
        assert_eq!(request.existing_device_name.as_deref(), Some("桌面副屏"));
        assert_ne!(request.id, id);
        assert_eq!(
            host.request_pairing_with_identity(
                &invite.session_id,
                &invite.secret,
                &claim,
                "新的型号名",
                Some(&identity),
                201,
            )
            .unwrap()
            .id,
            request.id
        );
        assert!(host
            .request_pairing_with_identity(
                &invite.session_id,
                &invite.secret,
                &claim,
                "新的型号名",
                Some(&secret()),
                201,
            )
            .is_err());
        assert!(host.claim(&request.id, &claim, 201).unwrap().is_none());
        assert!(host.authenticate(&old_token));
        // Failed persistence leaves the old connection and configuration untouched.
        let temp = host.path.with_extension("yaml.tmp");
        fs::create_dir(&temp).unwrap();
        assert!(host.approve(&request.id, 202).is_err());
        assert!(host.authenticate(&old_token));
        fs::remove_dir(temp).unwrap();
        host.approve(&request.id, 202).unwrap();
        let token = host.claim(&request.id, &claim, 203).unwrap().unwrap();
        assert_eq!(host.device_id(&token).as_deref(), Some(id.as_str()));
        assert!(!host.authenticate(&old_token));
        assert_eq!(host.devices.len(), 1);
        assert_eq!(serde_json::to_value(&host.devices[0]).unwrap(), original);
        drop(host);
        let restored = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert!(restored.authenticate(&token));
        assert!(!restored.authenticate(&old_token));
    }

    #[test]
    fn different_identities_and_legacy_clients_stay_separate_and_removal_starts_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let identity = secret();
        let (id, token) = pair_with_identity(&mut host, Some(&identity));
        pair_with_identity(&mut host, Some(&secret()));
        pair_with_identity(&mut host, None);
        pair_with_identity(&mut host, None);
        assert_eq!(host.devices.len(), 4);
        host.rename_device(&id, "旧配置").unwrap();
        host.revoke(&id).unwrap();
        assert!(!host.authenticate(&token));
        let (new_id, _) = pair_with_identity(&mut host, Some(&identity));
        assert_ne!(id, new_id);
        let device = host
            .devices
            .iter()
            .find(|device| device.id == new_id)
            .unwrap();
        assert_eq!(device.name, "同型号设备");
        assert_eq!(
            serde_json::to_value(&device.permissions).unwrap(),
            serde_json::to_value(Permissions::default()).unwrap()
        );
        assert!(device.layout.is_none());
        // Removing the original card also cancels an outstanding reconnect approval.
        let invite = host.invite(200);
        let claim = secret();
        let request = host
            .request_pairing_with_identity(
                &invite.session_id,
                &invite.secret,
                &claim,
                "同型号设备",
                Some(&identity),
                201,
            )
            .unwrap();
        host.revoke(&new_id).unwrap();
        assert!(host.approve(&request.id, 202).is_err());
    }

    #[test]
    fn legacy_identity_registration_requires_authentication_and_is_atomic_and_immutable() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let (id, token) = pair_with_identity(&mut host, None);
        let (_, other_token) = pair_with_identity(&mut host, None);
        let identity = secret();
        assert!(host
            .register_device_identity("invalid-token", &identity)
            .is_err());
        for invalid in ["", "serial-number", &"!".repeat(43)] {
            assert!(host.register_device_identity(&token, invalid).is_err());
        }
        let temp = host.path.with_extension("yaml.tmp");
        fs::create_dir(&temp).unwrap();
        assert!(host.register_device_identity(&token, &identity).is_err());
        assert!(host.devices[0].identity_hash.is_none());
        fs::remove_dir(&temp).unwrap();
        host.register_device_identity(&token, &identity).unwrap();
        host.register_device_identity(&token, &identity).unwrap();
        assert!(host.register_device_identity(&token, &secret()).is_err());
        assert!(host
            .register_device_identity(&other_token, &identity)
            .is_err());
        let (reused, _) = pair_with_identity(&mut host, Some(&identity));
        assert_eq!(reused, id);
        assert_eq!(host.devices.len(), 2);
    }

    #[test]
    fn rename_preserves_pairing_and_survives_restart_without_partial_writes() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let invite = host.invite(100);
        let claim = secret();
        let request = host
            .request_pairing(&invite.session_id, &invite.secret, &claim, "Xiaomi 14", 101)
            .unwrap();
        host.approve(&request.id, 102).unwrap();
        let token = host.claim(&request.id, &claim, 103).unwrap().unwrap();
        let original = serde_json::to_value(&host.devices[0]).unwrap();
        for invalid in ["", "  ", "a\nb", &"名".repeat(65)] {
            assert!(host.rename_device(&request.id, invalid).is_err());
        }
        assert!(host.rename_device("missing", "副屏").is_err());
        host.rename_device(&request.id, "  桌面副屏  ").unwrap();
        let mut expected = original;
        expected["name"] = serde_json::json!("桌面副屏");
        assert_eq!(serde_json::to_value(&host.devices[0]).unwrap(), expected);
        let revision = host.revision;
        let temp = host.path.with_extension("yaml.tmp");
        fs::create_dir(&temp).unwrap();
        assert!(host.rename_device(&request.id, "不应保存").is_err());
        assert_eq!(host.devices[0].name, "桌面副屏");
        assert_eq!(host.revision, revision);
        fs::remove_dir(temp).unwrap();
        drop(host);
        let restored = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(restored.devices[0].name, "桌面副屏");
        assert!(restored.authenticate(&token));
    }

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

    #[test]
    fn discovery_reuses_invitation_until_a_request_is_pending() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let first = host.discovery_invitation(100).unwrap();
        assert_eq!(
            host.discovery_invitation(101).unwrap().session_id,
            first.session_id
        );
        let claim = secret();
        let pending = host
            .request_pairing(&first.session_id, &first.secret, &claim, "屏幕", 102)
            .unwrap();
        assert!(host.discovery_invitation(103).is_none());
        assert_eq!(host.pending(103).unwrap().id, pending.id);
    }

    #[test]
    fn expired_pending_request_does_not_block_discovery() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let invitation = host.discovery_invitation(100).unwrap();
        host.request_pairing(
            &invitation.session_id,
            &invitation.secret,
            &secret(),
            "屏幕",
            101,
        )
        .unwrap();

        let next = host.discovery_invitation(invitation.expires_at).unwrap();
        assert_ne!(next.session_id, invitation.session_id);
        assert!(host.pending(invitation.expires_at).is_none());
    }
}
