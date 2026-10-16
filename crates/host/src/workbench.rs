//! Shared display data and the finite, device-scoped command gate.
use crate::{digest, matches, Host};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Permissions {
    pub sessions: bool,
    pub quota: bool,
    #[serde(default)]
    pub api_usage: bool,
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
pub struct ApiUsage {
    pub id: String,
    pub label: String,
    pub actual_cost_micros: i64,
    pub currency: String,
    pub token_count: u64,
    pub tpm: u64,
    pub window_start: u64,
    pub window_end: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Shortcut {
    pub shortcut_id: String,
    pub version: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub icon_png: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct ShortcutConfig {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub target: String,
    #[serde(default)]
    pub icon_png: String,
}

pub const MAX_ICON_BYTES: usize = 32 * 1024;
pub const MAX_SHORTCUT_ICON_BYTES: usize = 512 * 1024;

/// Only bounded raster data is shared; file paths and image metadata stay local.
pub fn validate_icon_png(value: &str) -> Result<usize> {
    if value.is_empty() {
        return Ok(0);
    }
    let invalid = "图标需为不超过 32 KB、最大 256 × 256 的 PNG 图片";
    ensure!(value.len() <= MAX_ICON_BYTES.div_ceil(3) * 4, invalid);
    let bytes = STANDARD.decode(value).context(invalid)?;
    ensure!(
        bytes.len() <= MAX_ICON_BYTES && bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        invalid
    );
    let mut decoder = png::Decoder::new(std::io::Cursor::new(&bytes));
    decoder.set_limits(png::Limits { bytes: 1024 * 1024 });
    let mut reader = decoder.read_info().context(invalid)?;
    let info = reader.info();
    ensure!(
        info.width > 0
            && info.width <= 256
            && info.height > 0
            && info.height <= 256
            && info.animation_control.is_none(),
        invalid
    );
    let mut output = vec![0; reader.output_buffer_size()];
    reader.next_frame(&mut output).context(invalid)?;
    Ok(bytes.len())
}

/// Re-encode decoded pixels so ancillary chunks cannot carry local metadata.
pub fn normalize_icon_png(value: &str) -> Result<String> {
    validate_icon_png(value)?;
    if value.is_empty() {
        return Ok(String::new());
    }
    let bytes = STANDARD.decode(value)?;
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    decoder.set_limits(png::Limits { bytes: 1024 * 1024 });
    let mut reader = decoder.read_info()?;
    let mut pixels = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut pixels)?;
    let mut output = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut output, info.width, info.height);
        encoder.set_color(info.color_type);
        encoder.set_depth(info.bit_depth);
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&pixels[..info.buffer_size()])?;
    }
    ensure!(
        output.len() <= MAX_ICON_BYTES,
        "图标转换后超过 32 KB，请使用更小的图片"
    );
    Ok(STANDARD.encode(output))
}

pub(crate) fn sanitize_shortcut_icons(items: &mut [ShortcutConfig]) {
    let mut total = 0;
    for item in items {
        match normalize_icon_png(&item.icon_png) {
            Ok(icon) => {
                let size = STANDARD.decode(&icon).map_or(0, |v| v.len());
                if total + size <= MAX_SHORTCUT_ICON_BYTES {
                    total += size;
                    item.icon_png = icon;
                } else {
                    item.icon_png.clear();
                }
            }
            Err(_) => item.icon_png.clear(),
        }
    }
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
            icon_png: self.icon_png.clone(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        validate_icon_png(&self.icon_png)?;
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
    pub api_usage: Vec<ApiUsage>,
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
    pub fn save_shortcut(&mut self, mut item: ShortcutConfig) -> Result<()> {
        item.icon_png = normalize_icon_png(&item.icon_png)?;
        item.validate()?;
        let previous = self.shortcuts.clone();
        if let Some(old) = self.shortcuts.iter_mut().find(|s| s.id == item.id) {
            *old = item;
        } else {
            ensure!(self.shortcuts.len() < 64, "最多保存 64 个入口");
            self.shortcuts.push(item);
        }
        let icon_budget = self.shortcuts.iter().try_fold(0usize, |total, item| {
            let total = total + validate_icon_png(&item.icon_png)?;
            ensure!(
                total <= MAX_SHORTCUT_ICON_BYTES,
                "入口图标总大小超过 512 KB，请减少图标或使用更小的图片"
            );
            Ok::<_, anyhow::Error>(total)
        });
        if let Err(e) = icon_budget.and_then(|_| self.save(&self.devices)) {
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
    pub fn reorder_shortcuts(&mut self, ids: &[String]) -> Result<()> {
        ensure!(
            ids.len() == self.shortcuts.len(),
            "入口已变化，请刷新后重新排序"
        );
        let mut remaining = self.shortcuts.clone();
        let mut ordered = Vec::with_capacity(ids.len());
        for id in ids {
            let index = remaining
                .iter()
                .position(|item| &item.id == id)
                .context("入口已变化，请刷新后重新排序")?;
            ordered.push(remaining.remove(index));
        }
        let previous = std::mem::replace(&mut self.shortcuts, ordered);
        if let Err(error) = self.save(&self.devices) {
            self.shortcuts = previous;
            return Err(error);
        }
        self.revision += 1;
        Ok(())
    }
    pub fn authorized_snapshot(&self, token: &str) -> Option<crate::Snapshot> {
        let id = self.device_id(token)?;
        self.device_snapshot(&id)
    }
    pub fn device_snapshot(&self, id: &str) -> Option<crate::Snapshot> {
        let device = self.devices.iter().find(|d| d.id == id)?;
        let permissions = &device.permissions;
        let mut snapshot = self.snapshot();
        snapshot.layout = device.layout.clone();
        snapshot.layout_revision = device.layout_revision;
        snapshot.sources.retain(|s| match s.source_id.as_str() {
            "codex.sessions" => permissions.sessions,
            "codex.quota" => permissions.quota,
            "sub2api.usage" => permissions.api_usage,
            _ => false,
        });
        if !permissions.sessions {
            snapshot.sessions.clear();
            snapshot.session_total = 0;
        }
        if !permissions.quota {
            snapshot.quotas.clear();
        }
        if !permissions.api_usage {
            snapshot.api_usage.clear();
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
    fn shortcut_order_is_persisted_and_projected_without_changing_actions() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "测试电脑".into()).unwrap();
        let (device, token) = paired(&mut host);
        host.set_permissions(
            &device,
            Permissions {
                shortcuts: true,
                open: true,
                ..Default::default()
            },
        )
        .unwrap();
        for name in ["一", "二", "三"] {
            host.save_shortcut(ShortcutConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: name.into(),
                kind: "url".into(),
                target: format!("https://example.com/{name}"),
                icon_png: String::new(),
            })
            .unwrap();
        }
        let original = host.shortcuts.clone();
        let ids = vec![
            original[2].id.clone(),
            original[0].id.clone(),
            original[1].id.clone(),
        ];
        let revision = host.revision;
        host.reorder_shortcuts(&ids).unwrap();
        assert_eq!(host.revision, revision + 1);
        let snapshot = host.authorized_snapshot(&token).unwrap();
        assert_eq!(
            snapshot
                .shortcuts
                .iter()
                .map(|item| item.shortcut_id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_eq!(snapshot.shortcuts[0].version, original[2].public().version);
        assert!(host
            .authorized_snapshot(&token)
            .unwrap()
            .capabilities
            .contains(&"open_shortcut".into()));
        drop(host);
        let restarted = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(
            restarted
                .shortcuts
                .iter()
                .map(|item| item.id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_eq!(restarted.shortcuts[0].target, original[2].target);
    }

    #[test]
    fn invalid_or_unsaved_shortcut_order_preserves_the_catalog() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "测试电脑".into()).unwrap();
        for name in ["一", "二"] {
            host.save_shortcut(ShortcutConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: name.into(),
                kind: "url".into(),
                target: "https://example.com".into(),
                icon_png: String::new(),
            })
            .unwrap();
        }
        let original = serde_json::to_value(&host.shortcuts).unwrap();
        let a = host.shortcuts[0].id.clone();
        let b = host.shortcuts[1].id.clone();
        let revision = host.revision;
        for ids in [
            vec![a.clone()],
            vec![a.clone(), a.clone()],
            vec![a.clone(), "unknown".into()],
            vec![a.clone(), b.clone(), "extra".into()],
        ] {
            assert!(host.reorder_shortcuts(&ids).is_err());
            assert_eq!(serde_json::to_value(&host.shortcuts).unwrap(), original);
            assert_eq!(host.revision, revision);
        }
        // A file at the storage-directory path makes the atomic save fail.
        let blocked = tempfile::tempdir().unwrap();
        let path = blocked.path().join("blocked");
        std::fs::write(&path, b"occupied").unwrap();
        host.path = path.join("host.yaml");
        assert!(host.reorder_shortcuts(&[b, a]).is_err());
        assert_eq!(serde_json::to_value(&host.shortcuts).unwrap(), original);
        assert_eq!(host.revision, revision);
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
            icon_png: String::new(),
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
    fn api_usage_is_opt_in_per_device_and_config_is_never_on_wire() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "测试电脑".into()).unwrap();
        let (device, token) = paired(&mut host);
        let (_, other) = paired(&mut host);
        // Persisted older permission records acquire a disabled API permission.
        let old: Permissions = serde_json::from_value(
            serde_json::json!({"sessions":true,"quota":true,"shortcuts":true,"open":true}),
        )
        .unwrap();
        assert!(!old.api_usage);
        host.set_usage_config(Some(crate::usage::UsageConfig {
            base_url: "https://example.com".into(),
            email: "private@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        }))
        .unwrap();
        host.workbench.api_usage.push(
            crate::usage::parse_usage(
                &serde_json::json!({"today_actual_cost":0,"today_tokens":12,"tpm":3}),
                "Asia/Shanghai",
                1792123200,
            )
            .unwrap(),
        );
        host.workbench.observed("sub2api.usage", Ok(()), 100, 180);
        assert!(host
            .authorized_snapshot(&token)
            .unwrap()
            .api_usage
            .is_empty());
        host.set_permissions(
            &device,
            Permissions {
                api_usage: true,
                ..Default::default()
            },
        )
        .unwrap();
        let snapshot = host.authorized_snapshot(&token).unwrap();
        assert_eq!(snapshot.api_usage[0].token_count, 12);
        assert_eq!(snapshot.sources[0].source_id, "sub2api.usage");
        assert!(snapshot.capabilities.is_empty());
        let wire = serde_json::to_string(&snapshot).unwrap();
        assert!(!wire.contains("private@example.com"));
        assert!(!wire.contains("https://example.com"));
        assert!(host
            .authorized_snapshot(&other)
            .unwrap()
            .api_usage
            .is_empty());
        host.set_permissions(&device, Permissions::default())
            .unwrap();
        let snapshot = host.authorized_snapshot(&token).unwrap();
        assert!(snapshot.api_usage.is_empty() && snapshot.sources.is_empty());
        drop(host);
        let mut host = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(
            host.usage_config.as_ref().unwrap().timezone,
            "Asia/Shanghai"
        );
        host.set_usage_config(None).unwrap();
        assert!(host.workbench.api_usage.is_empty());
    }
    #[test]
    fn shortcut_version_distinguishes_fields_with_delimiters() {
        let mut a = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "a".into(),
            kind: "url".into(),
            target: "https://x:url:https://y".into(),
            icon_png: String::new(),
        };
        let version = a.public().version;
        a.name = "a:url:https://x".into();
        a.target = "https://y".into();
        assert_ne!(version, a.public().version);
    }
    fn test_png(width: u32, height: u32, metadata: bool) -> String {
        let mut bytes = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut bytes, width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            if metadata {
                encoder
                    .add_text_chunk("Source".into(), "/Users/private/credentials".into())
                    .unwrap();
            }
            encoder
                .write_header()
                .unwrap()
                .write_image_data(&vec![128; (width * height * 4) as usize])
                .unwrap();
        }
        STANDARD.encode(bytes)
    }

    #[test]
    fn shortcut_icons_are_bounded_pixels_without_file_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let mut item = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "入口".into(),
            kind: "url".into(),
            target: "https://private.example/local-target".into(),
            icon_png: test_png(2, 2, true),
        };
        let version = item.public().version;
        host.save_shortcut(item.clone()).unwrap();
        let pixels = STANDARD.decode(&host.shortcuts[0].icon_png).unwrap();
        assert!(!String::from_utf8_lossy(&pixels).contains("credentials"));
        let wire = serde_json::to_string(&host.snapshot()).unwrap();
        assert!(
            wire.contains("icon_png") && !wire.contains("local-target") && !wire.contains("/Users")
        );
        item.icon_png.clear();
        assert_eq!(
            version,
            item.public().version,
            "display-only backfill must not invalidate opening"
        );
        for invalid in [
            "not base64".into(),
            STANDARD.encode(b"not a PNG"),
            test_png(257, 1, false),
            STANDARD.encode(vec![0; MAX_ICON_BYTES + 1]),
        ] {
            item.icon_png = invalid;
            assert!(host.save_shortcut(item.clone()).is_err());
        }
        let old: ShortcutConfig = serde_json::from_value(serde_json::json!({"id":item.id,"name":"旧入口","kind":"url","target":"https://example.com"})).unwrap();
        assert!(old.icon_png.is_empty());
        host.shortcuts[0].icon_png = "broken".into();
        host.save(&host.devices).unwrap();
        drop(host);
        let restored = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(
            restored.shortcuts[0].target,
            "https://private.example/local-target"
        );
        assert!(restored.shortcuts[0].icon_png.is_empty());
    }

    #[test]
    fn aggregate_icon_budget_rejects_without_modifying_existing_entries() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        // Deterministic noisy pixels produce a valid individual PNG near 16 KB.
        let mut bytes = Vec::new();
        let mut pixels = Vec::new();
        let mut seed = 91u32;
        for _ in 0..(64 * 64 * 4) {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            pixels.push(seed as u8);
        }
        {
            let mut encoder = png::Encoder::new(&mut bytes, 64, 64);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            encoder
                .write_header()
                .unwrap()
                .write_image_data(&pixels)
                .unwrap();
        }
        let icon = STANDARD.encode(bytes);
        let mut rejected = false;
        for i in 0..64 {
            let item = ShortcutConfig {
                id: uuid::Uuid::new_v4().to_string(),
                name: format!("入口{i}"),
                kind: "url".into(),
                target: "https://example.com".into(),
                icon_png: icon.clone(),
            };
            let count = host.shortcuts.len();
            if host.save_shortcut(item).is_err() {
                assert_eq!(host.shortcuts.len(), count);
                rejected = true;
                break;
            }
        }
        assert!(rejected);
        assert!(host.shortcuts.len() < 64);
        let total: usize = host
            .shortcuts
            .iter()
            .map(|s| validate_icon_png(&s.icon_png).unwrap())
            .sum();
        assert!(total <= MAX_SHORTCUT_ICON_BYTES);
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
                icon_png: String::new(),
            };
            assert!(item.validate().is_err(), "{target}");
        }
    }
}
