//! Local-only icon acquisition. Public catalogues contain normalized PNG pixels,
//! never the application path, image filename, URL or source image metadata.
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use deskbar_host::workbench::{normalize_icon_png, ShortcutConfig};
use serde::Serialize;
use std::path::Path;

#[derive(Serialize)]
pub struct ApplicationMetadata {
    pub target: String,
    pub name: String,
    pub icon_png: String,
}

pub fn application_metadata(path: &Path) -> Result<ApplicationMetadata> {
    let target = path.canonicalize().context("找不到所选应用")?;
    let name = target
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect::<String>();
    let item = ShortcutConfig {
        id: uuid::Uuid::new_v4().to_string(),
        name: name.trim().to_owned(),
        kind: "app".into(),
        target: target.to_string_lossy().into_owned(),
        icon_png: String::new(),
    };
    item.validate()?;
    Ok(ApplicationMetadata {
        icon_png: for_shortcut(&item).unwrap_or_default(),
        target: item.target,
        name: item.name,
    })
}

/// Acquisition is best effort: callers keep the configured action on failure.
pub fn for_shortcut(item: &ShortcutConfig) -> Result<String> {
    #[cfg(target_os = "macos")]
    {
        match item.kind.as_str() {
            "app" => {
                let path = Path::new(&item.target);
                workspace_icon(Some(path)).or_else(|_| resource_icon(path))
            }
            "url" => {
                static URL_ICON: std::sync::OnceLock<String> = std::sync::OnceLock::new();
                if let Some(icon) = URL_ICON.get() {
                    return Ok(icon.clone());
                }
                let icon = workspace_icon(None)?;
                let _ = URL_ICON.set(icon.clone());
                Ok(icon)
            }
            _ => Ok(String::new()),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = item;
        Ok(String::new())
    }
}

pub fn import_icon(path: &Path) -> Result<String> {
    ensure!(path.is_file(), "找不到图标文件");
    ensure!(
        path.metadata()?.len() <= 20 * 1024 * 1024,
        "请选择不超过 20 MB 的图片"
    );
    #[cfg(target_os = "macos")]
    {
        convert_icon(path)
    }
    #[cfg(not(target_os = "macos"))]
    {
        normalize_icon_png(&STANDARD.encode(std::fs::read(path).context("无法读取图标")?))
    }
}

#[cfg(target_os = "macos")]
fn convert_icon(path: &Path) -> Result<String> {
    let directory = tempfile::Builder::new().prefix("deskbar-icon-").tempdir()?;
    let output = directory.path().join("icon.png");
    let converted = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "png", "-Z", "64"])
        .arg(path)
        .arg("--out")
        .arg(&output)
        .output()
        .context("无法转换图标，请选择图片文件")?;
    ensure!(converted.status.success(), "无法转换图标，请选择图片文件");
    let bytes = std::fs::read(output).context("图标转换失败")?;
    normalize_icon_png(&STANDARD.encode(bytes))
}

#[cfg(target_os = "macos")]
fn workspace_icon(path: Option<&Path>) -> Result<String> {
    let bytes = objc2::rc::autoreleasepool(|_| {
        let workspace = objc2_app_kit::NSWorkspace::sharedWorkspace();
        let image = match path {
            Some(path) => workspace.iconForFile(&objc2_foundation::NSString::from_str(
                &path.to_string_lossy(),
            )),
            None =>
            {
                #[allow(deprecated)]
                workspace.iconForFileType(&objc2_foundation::NSString::from_str("webloc"))
            }
        };
        image.TIFFRepresentation().map(|data| data.to_vec())
    })
    .context("无法读取系统图标")?;
    let directory = tempfile::Builder::new()
        .prefix("deskbar-system-icon-")
        .tempdir()?;
    let image = directory.path().join("icon.tiff");
    std::fs::write(&image, bytes).context("无法转换系统图标")?;
    // Native extension icons may contain several large TIFF representations.
    // Only their normalized 64 px output is stored or sent to a device.
    convert_icon(&image)
}

#[cfg(target_os = "macos")]
fn resource_icon(path: &Path) -> Result<String> {
    let output = std::process::Command::new("/usr/bin/plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(path.join("Contents/Info.plist"))
        .output()
        .context("无法读取应用图标信息")?;
    ensure!(output.status.success(), "无法读取应用图标信息");
    let info: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let resources = path.join("Contents/Resources").canonicalize()?;
    let name = info["CFBundleIconFile"]
        .as_str()
        .or_else(|| info["CFBundleIconName"].as_str())
        .unwrap_or_default();
    let mut candidates = vec![resources.join(name), resources.join(format!("{name}.icns"))];
    if let Ok(files) = std::fs::read_dir(&resources) {
        candidates.extend(
            files
                .flatten()
                .map(|entry| entry.path())
                .filter(|p| p.extension().is_some_and(|extension| extension == "icns")),
        );
    }
    for candidate in candidates {
        // Bundle metadata cannot request images outside the selected bundle.
        let Ok(candidate) = candidate.canonicalize() else {
            continue;
        };
        if candidate.starts_with(&resources) && candidate.is_file() {
            if let Ok(icon) = import_icon(&candidate) {
                return Ok(icon);
            }
        }
    }
    anyhow::bail!("找不到可用的应用图标")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_real_application_and_url_system_icons() {
        let app = Path::new("/System/Applications/Notes.app");
        let metadata = application_metadata(app).unwrap();
        assert_eq!(metadata.name, "Notes");
        assert!(!metadata.icon_png.is_empty());
        assert!(deskbar_host::workbench::validate_icon_png(&metadata.icon_png).unwrap() <= 32768);
        let mut shortcut = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "网页".into(),
            kind: "url".into(),
            target: "https://private.example/a?token=secret".into(),
            icon_png: String::new(),
        };
        shortcut.icon_png = for_shortcut(&shortcut).unwrap();
        assert!(!shortcut.icon_png.is_empty());
        let public = serde_json::to_string(&shortcut.public()).unwrap();
        assert!(!public.contains("private.example") && !public.contains("secret"));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn existing_entries_are_backfilled_and_persisted_without_changing_action_version() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = deskbar_host::Host::load(dir.path().into(), "电脑".into()).unwrap();
        let item = ShortcutConfig {
            id: uuid::Uuid::new_v4().to_string(),
            name: "Notes".into(),
            kind: "app".into(),
            target: "/System/Applications/Notes.app".into(),
            icon_png: String::new(),
        };
        let version = item.public().version;
        host.save_shortcut(item).unwrap();
        let identity =
            crate::Identity::from_key(rcgen::KeyPair::generate().unwrap().serialize_pem()).unwrap();
        let agent = crate::Agent::with_identity(host, identity, 0)
            .await
            .unwrap();
        agent.start_shortcut_icons();
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                if !agent.status().shortcuts[0].icon_png.is_empty() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        })
        .await
        .unwrap();
        let status = agent.status();
        assert_eq!(status.shortcuts[0].public().version, version);
        assert!(std::fs::read_to_string(dir.path().join("host.yaml"))
            .unwrap()
            .contains("icon_png:"));
        let wire = serde_json::to_string(&status.workbench).unwrap();
        assert!(wire.contains("icon_png") && !wire.contains("/System/Applications"));
    }

    #[test]
    fn missing_images_do_not_import() {
        assert!(import_icon(Path::new("/missing/deskbar-icon.png")).is_err());
        assert!(application_metadata(Path::new("/missing/DeskBar.app")).is_err());
    }
}
