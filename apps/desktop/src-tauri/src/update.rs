use serde::Serialize;
use std::time::Duration;
use tauri::{AppHandle, State};
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::Mutex;

#[derive(Default)]
pub struct PendingUpdate(Mutex<Option<Update>>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    current_version: String,
    version: Option<String>,
}

fn newer_stable(current: &semver::Version, release: &semver::Version) -> bool {
    release.pre.is_empty() && release.build.is_empty() && release > current
}

#[tauri::command]
pub async fn update_check(
    app: AppHandle,
    state: State<'_, PendingUpdate>,
) -> Result<Offer, String> {
    let mut pending = state.0.try_lock().map_err(|_| "更新操作正在进行")?;
    // A failed refresh must not leave a stale install offer.
    *pending = None;
    let update = app
        .updater_builder()
        .timeout(Duration::from_secs(30))
        .version_comparator(|current, release| newer_stable(&current, &release.version))
        .build()
        .map_err(|_| "无法初始化更新，请重新安装正式版本")?
        .check()
        .await
        .map_err(|_| "无法检查更新，请稍后重试；首次发布前可能还没有可用版本")?;
    let offer = Offer {
        current_version: app.package_info().version.to_string(),
        version: update.as_ref().map(|u| u.version.clone()),
    };
    *pending = update;
    Ok(offer)
}

#[tauri::command]
pub async fn update_install(app: AppHandle, state: State<'_, PendingUpdate>) -> Result<(), String> {
    let mut pending = state.0.try_lock().map_err(|_| "更新操作正在进行")?;
    let mut update = pending.take().ok_or("请先检查更新")?;
    update.timeout = Some(Duration::from_secs(300));
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|_| "更新未完成，请检查网络后重新检查更新")?;
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_only_newer_stable_versions() {
        let current = semver::Version::parse("0.1.2").unwrap();
        for version in ["0.1.1", "0.1.2", "0.2.0-rc.1", "0.2.0+test"] {
            assert!(!newer_stable(
                &current,
                &semver::Version::parse(version).unwrap()
            ));
        }
        assert!(newer_stable(
            &current,
            &semver::Version::parse("0.1.3").unwrap()
        ));
    }
}
