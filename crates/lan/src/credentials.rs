//! Desktop credentials live in a private local file. The keyring is read only
//! when importing an existing installation; normal startup never touches it.
use crate::Identity;
use anyhow::{ensure, Context, Result};
use deskbar_host::{usage::UsageConfig, Host};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Write, path::PathBuf};

const IDENTITY_SERVICE: &str = "app.deskbar.agent";
const USAGE_SERVICE: &str = "app.deskbar.agent.sub2api";

pub(super) fn credential_account(host: &str, config: &UsageConfig) -> String {
    let identity =
        serde_json::to_vec(&(&config.base_url, &config.email)).expect("strings serialize");
    format!("{host}:{:x}", Sha256::digest(identity))
}

#[derive(Clone, Serialize, Deserialize)]
struct StoredCredentials {
    version: u32,
    host_id: String,
    tls_key_pem: String,
    usage_passwords: BTreeMap<String, String>,
}

pub(super) struct Credentials {
    path: PathBuf,
    stored: StoredCredentials,
}

impl Credentials {
    pub fn load(host: &Host, existing_host: bool) -> Result<Self> {
        Self::load_with_legacy(host, existing_host, read_legacy)
    }

    fn load_with_legacy(
        host: &Host,
        existing_host: bool,
        mut read: impl FnMut(&str, &str) -> Result<Option<String>>,
    ) -> Result<Self> {
        if let Some(store) = Self::read(host)? {
            return Ok(store);
        }
        let key = if existing_host {
            read(IDENTITY_SERVICE, &host.id).context(
                "首次升级需读取旧电脑身份，请允许一次钥匙串访问；迁移成功后不再访问钥匙串",
            )?
        } else {
            None
        };
        ensure!(
            key.is_some() || host.devices.is_empty(),
            "原电脑身份凭据缺失，请恢复本机凭据文件或旧钥匙串条目；为保留配对，未生成新身份"
        );
        let key = match key {
            Some(key) => key,
            None => rcgen::KeyPair::generate()?.serialize_pem(),
        };
        let mut store = Self::new(host, key)?;
        if existing_host {
            if let Some(config) = &host.usage_config {
                let account = credential_account(&host.id, config);
                // A denied/missing API password must not stop LAN connections or
                // cause another keychain prompt every collector retry. The source
                // asks for the password again in Settings; the legacy copy stays.
                if let Ok(Some(password)) = read(USAGE_SERVICE, &account) {
                    store.stored.usage_passwords.insert(account, password);
                }
            }
        }
        store.persist(&store.stored)?;
        Ok(store)
    }

    // Explicit identities are used by the isolated TLS/Android test fixtures.
    pub fn with_identity(host: &Host, identity: &Identity) -> Result<Self> {
        if let Some(store) = Self::read(host)? {
            ensure!(
                store.identity()?.pin == identity.pin,
                "电脑身份与本机凭据不一致"
            );
            return Ok(store);
        }
        let store = Self::new(host, identity.key_pem.clone())?;
        store.persist(&store.stored)?;
        Ok(store)
    }

    fn path(host: &Host) -> PathBuf {
        host.data_directory().join("credentials").join("store.json")
    }

    fn new(host: &Host, key: String) -> Result<Self> {
        let store = Self {
            path: Self::path(host),
            stored: StoredCredentials {
                version: 1,
                host_id: host.id.clone(),
                tls_key_pem: key,
                usage_passwords: BTreeMap::new(),
            },
        };
        store.identity()?;
        Ok(store)
    }

    fn read(host: &Host) -> Result<Option<Self>> {
        let path = Self::path(host);
        Self::private_directory(path.parent().unwrap())?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => anyhow::bail!("无法读取本机凭据，请检查应用数据目录权限"),
        };
        ensure!(
            metadata.is_file(),
            "本机凭据必须是普通文件，请保留原文件并检查"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                .context("无法设置本机凭据文件权限")?;
        }
        let bytes = fs::read(&path).context("无法读取本机凭据，请检查应用数据目录权限")?;
        // Do not attach serde's error: unexpected field values may be secrets.
        let stored: StoredCredentials = serde_json::from_slice(&bytes)
            .map_err(|_| anyhow::anyhow!("本机凭据文件损坏，请保留原文件并从备份恢复"))?;
        ensure!(stored.version == 1, "本机凭据版本不受支持，请更新连接助手");
        ensure!(
            stored.host_id == host.id,
            "本机凭据与电脑配置不匹配，请恢复对应备份"
        );
        let store = Self { path, stored };
        store.identity()?;
        Ok(Some(store))
    }

    pub fn identity(&self) -> Result<Identity> {
        Identity::from_key(self.stored.tls_key_pem.clone())
            .map_err(|_| anyhow::anyhow!("本机电脑身份无效，请保留凭据文件并从备份恢复"))
    }

    pub fn password(&self, account: &str) -> Option<String> {
        self.stored.usage_passwords.get(account).cloned()
    }

    pub fn set_password(&mut self, account: &str, password: Option<&str>) -> Result<()> {
        let mut next = self.stored.clone();
        match password {
            Some(value) => {
                next.usage_passwords.insert(account.into(), value.into());
            }
            None => {
                next.usage_passwords.remove(account);
            }
        }
        self.persist(&next)?;
        self.stored = next;
        Ok(())
    }

    fn private_directory(path: &std::path::Path) -> Result<()> {
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        match builder.create(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e).context("无法创建本机凭据目录"),
        }
        ensure!(
            fs::symlink_metadata(path)?.is_dir(),
            "本机凭据目录无效，请保留原文件并检查"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))
                .context("无法设置本机凭据目录权限")?;
        }
        Ok(())
    }

    fn persist(&self, stored: &StoredCredentials) -> Result<()> {
        let directory = self.path.parent().unwrap();
        Self::private_directory(directory)?;
        let mut temp = tempfile::NamedTempFile::new_in(directory)
            .context("无法保存本机凭据，请检查应用数据目录权限")?;
        // NamedTempFile creates files with mode 0600 on Unix, including before
        // the first secret is written. Replacement retains those permissions.
        temp.write_all(&serde_json::to_vec(stored)?)?;
        temp.as_file().sync_all()?;
        temp.persist(&self.path)
            .map_err(|_| anyhow::anyhow!("无法保存本机凭据，请检查应用数据目录权限"))?;
        Ok(())
    }
}

fn read_legacy(service: &str, account: &str) -> Result<Option<String>> {
    let entry = keyring::Entry::new(service, account)
        .map_err(|_| anyhow::anyhow!("无法访问旧钥匙串条目"))?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => anyhow::bail!("无法读取旧钥匙串条目"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> UsageConfig {
        UsageConfig {
            base_url: "https://usage.example.com".into(),
            email: "fixture@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        }
    }

    fn no_keyring(_: &str, _: &str) -> Result<Option<String>> {
        panic!("local credentials must not access the system keyring")
    }

    fn pair(host: &mut Host) -> String {
        let invite = host.invite(100);
        let claim = deskbar_host::secret();
        let request = host
            .request_pairing(&invite.session_id, &invite.secret, &claim, "fixture", 101)
            .unwrap();
        host.approve(&request.id, 102).unwrap();
        host.claim(&request.id, &claim, 103).unwrap().unwrap()
    }

    #[test]
    fn new_install_and_restarts_use_only_local_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        let mut credentials = Credentials::load_with_legacy(&host, false, no_keyring).unwrap();
        let pin = credentials.identity().unwrap().pin;
        let account = credential_account(&host.id, &config());
        credentials
            .set_password(&account, Some("fixture-password"))
            .unwrap();
        host.set_usage_config(Some(config())).unwrap();
        let token = pair(&mut host);
        let host_id = host.id.clone();
        drop(credentials);
        drop(host);

        let host = Host::load(dir.path().into(), "ignored".into()).unwrap();
        let credentials = Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
        assert_eq!(host.id, host_id);
        assert!(host.authenticate(&token));
        assert_eq!(credentials.identity().unwrap().pin, pin);
        assert_eq!(
            credentials.password(&account).as_deref(),
            Some("fixture-password")
        );
        let yaml = fs::read_to_string(dir.path().join("host.yaml")).unwrap();
        assert!(!yaml.contains("fixture-password"));
        assert!(!yaml.contains("PRIVATE KEY"));
        let snapshot = serde_json::to_string(&host.snapshot()).unwrap();
        assert!(!snapshot.contains("fixture-password"));
        assert!(!snapshot.contains("PRIVATE KEY"));
    }

    #[test]
    fn migration_preserves_identity_pairing_and_password_without_reading_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        host.set_usage_config(Some(config())).unwrap();
        let token = pair(&mut host);
        let original =
            Identity::from_key(rcgen::KeyPair::generate().unwrap().serialize_pem()).unwrap();
        let account = credential_account(&host.id, &config());
        let mut reads = Vec::new();
        let credentials = Credentials::load_with_legacy(&host, true, |service, key| {
            reads.push((service.to_string(), key.to_string()));
            match service {
                IDENTITY_SERVICE => Ok(Some(original.key_pem.clone())),
                USAGE_SERVICE => Ok(Some("imported-password".into())),
                _ => panic!("unexpected keyring service"),
            }
        })
        .unwrap();
        assert_eq!(
            reads,
            vec![
                (IDENTITY_SERVICE.into(), host.id.clone()),
                (USAGE_SERVICE.into(), account.clone()),
            ]
        );
        assert_eq!(credentials.identity().unwrap().pin, original.pin);
        assert_eq!(
            credentials.password(&account).as_deref(),
            Some("imported-password")
        );
        drop(credentials);
        drop(host);
        let host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        assert!(host.authenticate(&token));
        let mut credentials = Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
        assert_eq!(credentials.identity().unwrap().pin, original.pin);
        credentials.set_password(&account, None).unwrap();
        let credentials = Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
        assert!(credentials.password(&account).is_none());
    }

    #[test]
    fn failed_identity_import_preserves_pairing_and_does_not_commit() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        let token = pair(&mut host);
        assert!(
            Credentials::load_with_legacy(&host, true, |_, _| anyhow::bail!("denied")).is_err()
        );
        assert!(Credentials::load_with_legacy(&host, true, |_, _| Ok(None)).is_err());
        assert!(!Credentials::path(&host).exists());
        assert!(host.authenticate(&token));
    }

    #[test]
    fn denied_usage_import_does_not_block_connections_or_repeat_prompts() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        host.set_usage_config(Some(config())).unwrap();
        let key = rcgen::KeyPair::generate().unwrap().serialize_pem();
        let credentials = Credentials::load_with_legacy(&host, true, |service, _| {
            if service == IDENTITY_SERVICE {
                Ok(Some(key.clone()))
            } else {
                anyhow::bail!("denied")
            }
        })
        .unwrap();
        assert!(credentials
            .password(&credential_account(&host.id, &config()))
            .is_none());
        assert!(credentials.identity().is_ok());
        Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
    }

    #[test]
    fn damaged_unknown_or_mismatched_credentials_are_never_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        let credentials = Credentials::load_with_legacy(&host, false, no_keyring).unwrap();
        let original = serde_json::to_value(&credentials.stored).unwrap();
        let mut future = original.clone();
        future["version"] = 2.into();
        let mut wrong_host = original.clone();
        wrong_host["host_id"] = "another-host".into();
        let mut wrong_key = original;
        wrong_key["tls_key_pem"] = "fixture-secret-invalid-key".into();
        for content in [
            b"{broken fixture-secret".to_vec(),
            serde_json::to_vec(&future).unwrap(),
            serde_json::to_vec(&wrong_host).unwrap(),
            serde_json::to_vec(&wrong_key).unwrap(),
        ] {
            fs::write(&credentials.path, &content).unwrap();
            let error = Credentials::load_with_legacy(&host, true, no_keyring)
                .err()
                .unwrap();
            assert!(!format!("{error:#}").contains("fixture-secret"));
            assert_eq!(fs::read(&credentials.path).unwrap(), content);
        }
    }

    #[test]
    fn failed_atomic_write_keeps_previous_password() {
        let dir = tempfile::tempdir().unwrap();
        let host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        let mut credentials = Credentials::load_with_legacy(&host, false, no_keyring).unwrap();
        credentials
            .set_password("account", Some("old-password"))
            .unwrap();
        let backup = credentials.path.with_extension("backup");
        fs::rename(&credentials.path, &backup).unwrap();
        fs::create_dir(&credentials.path).unwrap();
        assert!(credentials
            .set_password("account", Some("new-password"))
            .is_err());
        assert_eq!(
            credentials.password("account").as_deref(),
            Some("old-password")
        );
        fs::remove_dir(&credentials.path).unwrap();
        fs::rename(backup, &credentials.path).unwrap();
        let credentials = Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
        assert_eq!(
            credentials.password("account").as_deref(),
            Some("old-password")
        );
    }

    #[cfg(unix)]
    #[test]
    fn local_credentials_are_private_after_create_replace_and_reopen() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let host = Host::load(dir.path().into(), "fixture".into()).unwrap();
        let mut credentials = Credentials::load_with_legacy(&host, false, no_keyring).unwrap();
        for replace in [false, true] {
            if replace {
                credentials.set_password("account", Some("secret")).unwrap();
            }
            assert_eq!(
                fs::metadata(&credentials.path)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(credentials.path.parent().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
        fs::set_permissions(&credentials.path, fs::Permissions::from_mode(0o644)).unwrap();
        fs::set_permissions(
            credentials.path.parent().unwrap(),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        Credentials::load_with_legacy(&host, true, no_keyring).unwrap();
        assert_eq!(
            fs::metadata(&credentials.path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(credentials.path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }
}
