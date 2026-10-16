//! Shared display data and the finite, device-scoped command gate.
use crate::{digest, matches, Host};
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Permissions {
    pub sessions: bool,
    pub quota: bool,
    pub shortcuts: bool,
    pub open: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourceState {
    pub source_id: String,
    pub health: String,
    pub message: String,
    pub observed_at: u64,
    pub fresh_until: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub version: String,
    pub title: String,
    pub project: String,
    pub status: String,
    pub updated_at: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Quota {
    pub id: String,
    pub label: String,
    pub remaining_percent: f64,
    pub resets_at: u64,
    pub window_minutes: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Shortcut {
    pub shortcut_id: String,
    pub version: String,
    pub name: String,
    pub kind: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct ShortcutConfig {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub target: String,
}
impl ShortcutConfig {
    pub fn public(&self) -> Shortcut {
        Shortcut {
            shortcut_id: self.id.clone(),
            version: digest(
                &serde_json::to_string(&(&self.name, &self.kind, &self.target))
                    .expect("strings serialize"),
            ),
            name: self.name.clone(),
            kind: self.kind.clone(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(uuid::Uuid::parse_str(&self.id).is_ok(), "入口编号无效");
        ensure!(
            !self.name.trim().is_empty() && self.name.chars().count() <= 64,
            "请输入不超过 64 字的名称"
        );
        ensure!(
            self.target.len() <= 4096
                && self.target.trim() == self.target
                && !self.target.chars().any(char::is_control),
            "入口地址无效"
        );
        match self.kind.as_str() {
            "url" => {
                let u = url::Url::parse(&self.target).context("请输入完整的网址")?;
                ensure!(
                    matches!(u.scheme(), "https" | "http")
                        && u.host_str().is_some()
                        && u.username().is_empty()
                        && u.password().is_none(),
                    "网址须以 https:// 或 http:// 开头，且不包含登录凭据"
                );
            }
            "app" => {
                let path = std::path::Path::new(&self.target);
                ensure!(path.is_absolute() && path.exists(), "应用路径不存在");
                #[cfg(target_os = "macos")]
                ensure!(
                    path.extension().is_some_and(|x| x == "app") && path.is_dir(),
                    "请选择 .app 应用"
                );
                #[cfg(not(target_os = "macos"))]
                ensure!(path.is_file(), "请选择应用文件");
            }
            _ => bail!("请选择网页或应用"),
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct Workbench {
    pub sources: Vec<SourceState>,
    pub sessions: Vec<Session>,
    pub session_total: usize,
    pub quotas: Vec<Quota>,
}
impl Workbench {
    pub fn observed(&mut self, id: &str, result: Result<()>, time: u64, ttl: u64) {
        let index = self.sources.iter().position(|s| s.source_id == id);
        let previous = index.map(|i| &self.sources[i]);
        let state = SourceState {
            source_id: id.into(),
            health: if result.is_ok() { "ready" } else { "error" }.into(),
            message: result
                .as_ref()
                .err()
                .map(ToString::to_string)
                .unwrap_or_default(),
            observed_at: if result.is_ok() {
                time
            } else {
                previous.map_or(0, |s| s.observed_at)
            },
            fresh_until: if result.is_ok() {
                time + ttl
            } else {
                previous.map_or(0, |s| s.fresh_until)
            },
        };
        if let Some(i) = index {
            self.sources[i] = state;
        } else {
            self.sources.push(state);
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    pub command_id: String,
    pub host_id: String,
    pub host_epoch: String,
    pub action: String,
    pub target_id: String,
    pub target_version: String,
    pub expires_at: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CommandResult {
    pub command_id: String,
    pub status: String,
    pub message: String,
}
#[derive(Clone)]
pub enum OpenTarget {
    Session(String),
    Shortcut(ShortcutConfig),
}
impl Host {
    pub fn device_id(&self, token: &str) -> Option<String> {
        let hash = digest(token);
        self.devices
            .iter()
            .find(|d| matches(&d.token_hash, &hash))
            .map(|d| d.id.clone())
    }
    pub fn set_permissions(&mut self, id: &str, permissions: Permissions) -> Result<()> {
        let mut devices = self.devices.clone();
        devices
            .iter_mut()
            .find(|d| d.id == id)
            .context("设备已移除")?
            .permissions = permissions;
        self.save(&devices)?;
        self.devices = devices;
        self.revision += 1;
        Ok(())
    }
    pub fn save_shortcut(&mut self, item: ShortcutConfig) -> Result<()> {
        item.validate()?;
        let previous = self.shortcuts.clone();
        if let Some(old) = self.shortcuts.iter_mut().find(|s| s.id == item.id) {
            *old = item;
        } else {
            ensure!(self.shortcuts.len() < 64, "最多保存 64 个入口");
            self.shortcuts.push(item);
        }
        if let Err(e) = self.save(&self.devices) {
            self.shortcuts = previous;
            return Err(e);
        }
        self.revision += 1;
        Ok(())
    }
    pub fn remove_shortcut(&mut self, id: &str) -> Result<()> {
        let previous = self.shortcuts.clone();
        self.shortcuts.retain(|s| s.id != id);
        if let Err(e) = self.save(&self.devices) {
            self.shortcuts = previous;
            return Err(e);
        }
        self.revision += 1;
        Ok(())
    }
    pub fn authorized_snapshot(&self, token: &str) -> Option<crate::Snapshot> {
        let id = self.device_id(token)?;
        let permissions = &self.devices.iter().find(|d| d.id == id)?.permissions;
        let mut snapshot = self.snapshot();
        snapshot.sources.retain(|s| match s.source_id.as_str() {
            "codex.sessions" => permissions.sessions,
            "codex.quota" => permissions.quota,
            _ => false,
        });
        if !permissions.sessions {
            snapshot.sessions.clear();
            snapshot.session_total = 0;
        }
        if !permissions.quota {
            snapshot.quotas.clear();
        }
        if !permissions.shortcuts {
            snapshot.shortcuts.clear();
        }
        if permissions.open {
            if permissions.sessions {
                snapshot.capabilities.push("open_session".into());
            }
            if permissions.shortcuts {
                snapshot.capabilities.push("open_shortcut".into());
            }
        }
        Some(snapshot)
    }
    pub fn prepare_command(
        &mut self,
        device: &str,
        command: Command,
        time: u64,
    ) -> Result<(CommandResult, Option<OpenTarget>)> {
        let p = &self
            .devices
            .iter()
            .find(|d| d.id == device)
            .context("设备已移除")?
            .permissions;
        let key = (device.to_owned(), command.command_id.clone());
        if let Some((old, result)) = self.commands.get(&key) {
            ensure!(old == &command, "同一动作编号不能用于不同请求");
            return Ok((result.clone(), None));
        }
        ensure!(
            uuid::Uuid::parse_str(&command.command_id).is_ok(),
            "动作编号无效"
        );
        ensure!(
            command.host_id == self.id && command.host_epoch == self.epoch,
            "电脑状态已变化，请刷新后再试"
        );
        ensure!(
            command.expires_at > time && command.expires_at <= time.saturating_add(10),
            "请求已过期，请重新点击"
        );
        ensure!(p.open, "请在电脑上允许这台设备打开内容");
        let target = match command.action.as_str() {
            "open_session" => {
                ensure!(p.sessions, "这台设备无权访问会话");
                ensure!(
                    self.workbench
                        .sources
                        .iter()
                        .any(|s| s.source_id == "codex.sessions"
                            && s.health == "ready"
                            && s.fresh_until > time),
                    "会话状态已过期，请等待刷新"
                );
                let s = self
                    .workbench
                    .sessions
                    .iter()
                    .find(|s| {
                        s.session_id == command.target_id && s.version == command.target_version
                    })
                    .context("会话已变化，请刷新后再试")?;
                ensure!(uuid::Uuid::parse_str(&s.session_id).is_ok(), "会话编号无效");
                OpenTarget::Session(s.session_id.clone())
            }
            "open_shortcut" => {
                ensure!(p.shortcuts, "这台设备无权访问入口");
                let s = self
                    .shortcuts
                    .iter()
                    .find(|s| {
                        s.id == command.target_id && s.public().version == command.target_version
                    })
                    .context("入口已变化，请刷新后再试")?;
                s.validate()?;
                OpenTarget::Shortcut(s.clone())
            }
            _ => bail!("不支持这项操作"),
        };
        // Never evict an ID during this epoch: a repeated request cannot execute again.
        ensure!(self.commands.len() < 4096, "动作记录已满，请重启连接助手");
        let result = CommandResult {
            command_id: command.command_id.clone(),
            status: "accepted".into(),
            message: "电脑已接收，正在打开".into(),
        };
        self.commands.insert(key, (command, result.clone()));
        Ok((result, Some(target)))
    }
    pub fn finish_command(&mut self, device: &str, id: &str, status: &str, message: &str) {
        if let Some((_, r)) = self.commands.get_mut(&(device.into(), id.into())) {
            r.status = status.into();
            r.message = message.into();
        }
    }
    pub fn command_result(&self, device: &str, id: &str) -> CommandResult {
        self.commands
            .get(&(device.into(), id.into()))
            .map(|(_, r)| r.clone())
            .unwrap_or_else(|| CommandResult {
                command_id: id.into(),
                status: "unknown".into(),
                message: "找不到执行记录，结果未知；请先查看电脑".into(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn paired(host: &mut Host) -> (String, String) {
        let invite = host.invite(100);
        let claim = crate::secret();
        let pending = host
            .request_pairing(&invite.session_id, &invite.secret, &claim, "测试屏幕", 101)
            .unwrap();
        host.approve(&pending.id, 102).unwrap();
        (
            pending.id.clone(),
            host.claim(&pending.id, &claim, 103).unwrap().unwrap(),
        )
    }
    #[test]
    fn device_projection_persistence_and_command_at_most_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "测试电脑".into()).unwrap();
        let (device, token) = paired(&mut host);
        let (_, other) = paired(&mut host);
        let shortcut = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "网页".into(),
            kind: "url".into(),
            target: "https://example.com/private-path".into(),
        };
        host.save_shortcut(shortcut.clone()).unwrap();
        let public = shortcut.public();
        assert!(host
            .authorized_snapshot(&token)
            .unwrap()
            .shortcuts
            .is_empty());
        host.set_permissions(
            &device,
            Permissions {
                shortcuts: true,
                open: true,
                ..Default::default()
            },
        )
        .unwrap();
        let wire = serde_json::to_string(&host.authorized_snapshot(&token).unwrap()).unwrap();
        assert!(wire.contains(&public.shortcut_id));
        assert!(!wire.contains("private-path"));
        assert!(host
            .authorized_snapshot(&other)
            .unwrap()
            .shortcuts
            .is_empty());
        let command = Command {
            command_id: uuid::Uuid::new_v4().to_string(),
            host_id: host.id.clone(),
            host_epoch: host.epoch.clone(),
            action: "open_shortcut".into(),
            target_id: public.shortcut_id,
            target_version: public.version,
            expires_at: 110,
        };
        let (accepted, target) = host.prepare_command(&device, command.clone(), 104).unwrap();
        assert_eq!(accepted.status, "accepted");
        assert!(target.is_some());
        host.finish_command(&device, &command.command_id, "succeeded", "已打开");
        assert!(host
            .prepare_command(&device, command.clone(), 105)
            .unwrap()
            .1
            .is_none());
        assert_eq!(
            host.prepare_command(&device, command.clone(), 200)
                .unwrap()
                .0
                .status,
            "succeeded"
        );
        let mut conflict = command.clone();
        conflict.target_id = "other".into();
        assert!(host.prepare_command(&device, conflict, 105).is_err());
        let other_id = host.device_id(&other).unwrap();
        assert_eq!(
            host.command_result(&other_id, &command.command_id).status,
            "unknown"
        );
        let mut retry = command.clone();
        retry.command_id = uuid::Uuid::new_v4().to_string();
        assert!(host.prepare_command(&device, retry.clone(), 110).is_err());
        retry.expires_at = 200;
        assert!(host.prepare_command(&device, retry.clone(), 105).is_err());
        retry.expires_at = 110;
        retry.target_version = "old".into();
        assert!(host.prepare_command(&device, retry.clone(), 105).is_err());
        retry.target_version = command.target_version.clone();
        host.set_permissions(
            &device,
            Permissions {
                shortcuts: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(host.prepare_command(&device, retry.clone(), 105).is_err());
        let epoch = host.epoch.clone();
        drop(host);
        let mut restarted = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_ne!(restarted.epoch, epoch);
        assert!(restarted
            .authorized_snapshot(&token)
            .unwrap()
            .capabilities
            .is_empty());
        assert_eq!(restarted.shortcuts.len(), 1);
        restarted
            .set_permissions(
                &device,
                Permissions {
                    shortcuts: true,
                    open: true,
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(restarted.prepare_command(&device, retry, 105).is_err());
    }
    #[test]
    fn failed_source_keeps_original_freshness_and_values() {
        let mut state = Workbench::default();
        state.observed("codex.sessions", Ok(()), 100, 20);
        state.observed("codex.sessions", Err(anyhow::anyhow!("不可用")), 110, 20);
        assert_eq!(state.sources[0].observed_at, 100);
        assert_eq!(state.sources[0].fresh_until, 120);
        assert_eq!(state.sources[0].health, "error");
    }
    #[test]
    fn shortcut_version_distinguishes_fields_with_delimiters() {
        let mut a = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "a".into(),
            kind: "url".into(),
            target: "https://x:url:https://y".into(),
        };
        let version = a.public().version;
        a.name = "a:url:https://x".into();
        a.target = "https://y".into();
        assert_ne!(version, a.public().version);
    }
    #[test]
    fn reject_unbounded_shortcut_targets() {
        for target in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://user:password@example.com",
            "--help",
            "https://example.com\n",
        ] {
            let item = ShortcutConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: "测试".into(),
                kind: "url".into(),
                target: target.into(),
            };
            assert!(item.validate().is_err(), "{target}");
        }
    }
}
