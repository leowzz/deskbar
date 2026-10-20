#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod recent_apps;
mod update;
use deskbar_lan::{Agent, AgentStatus, PairingInvitation};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager, State,
};

struct AgentState(Result<Agent, String>);
impl AgentState {
    fn agent(&self) -> Result<&Agent, String> {
        self.0.as_ref().map_err(Clone::clone)
    }
}

#[tauri::command]
fn agent_status(state: State<AgentState>) -> Result<AgentStatus, String> {
    Ok(state.agent()?.status())
}
#[tauri::command]
fn device_workbench(
    state: State<AgentState>,
    id: String,
) -> Result<deskbar_host::Snapshot, String> {
    state
        .agent()?
        .host
        .lock()
        .unwrap()
        .device_snapshot(&id)
        .ok_or_else(|| "设备已移除".into())
}
#[tauri::command]
fn save_layout(
    state: State<AgentState>,
    id: String,
    expected_revision: u64,
    layout: deskbar_host::layout::LayoutDocument,
) -> Result<u64, String> {
    state
        .agent()?
        .save_layout(&id, expected_revision, layout)
        .map_err(|e| e.to_string())
}
#[tauri::command]
fn create_invitation(state: State<AgentState>) -> Result<PairingInvitation, String> {
    state.agent()?.invite().map_err(|e| e.to_string())
}
#[tauri::command]
fn cancel_pairing(state: State<AgentState>) -> Result<(), String> {
    state.agent()?.cancel_pairing();
    Ok(())
}
#[tauri::command]
fn approve_device(state: State<AgentState>, id: String) -> Result<(), String> {
    state.agent()?.approve(&id).map_err(|e| e.to_string())
}
#[tauri::command]
fn revoke_device(state: State<AgentState>, id: String) -> Result<(), String> {
    state.agent()?.revoke(&id).map_err(|e| e.to_string())
}

#[tauri::command]
fn rename_device(state: State<AgentState>, id: String, name: String) -> Result<(), String> {
    state
        .agent()?
        .rename_device(&id, &name)
        .map_err(|e| e.to_string())
}
#[tauri::command]
fn set_permissions(
    state: State<AgentState>,
    id: String,
    permissions: deskbar_host::workbench::Permissions,
) -> Result<(), String> {
    state
        .agent()?
        .set_permissions(&id, permissions)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn save_shortcut(
    state: State<'_, AgentState>,
    item: deskbar_host::workbench::ShortcutConfig,
) -> Result<(), String> {
    let agent = state.agent()?.clone();
    tauri::async_runtime::spawn_blocking(move || agent.save_shortcut(item))
        .await
        .map_err(|_| "无法保存入口".to_string())?
        .map_err(|e| e.to_string())
}
#[tauri::command]
fn remove_shortcut(state: State<AgentState>, id: String) -> Result<(), String> {
    state
        .agent()?
        .remove_shortcut(&id)
        .map_err(|e| e.to_string())
}
#[tauri::command]
fn reorder_shortcuts(state: State<AgentState>, ids: Vec<String>) -> Result<(), String> {
    state
        .agent()?
        .reorder_shortcuts(&ids)
        .map_err(|e| e.to_string())
}
#[tauri::command]
fn refresh_sources(state: State<AgentState>) -> Result<(), String> {
    state.agent()?.refresh_sources();
    Ok(())
}

#[tauri::command]
async fn save_usage_source(
    state: State<'_, AgentState>,
    config: deskbar_host::usage::UsageConfig,
    password: String,
) -> Result<(), String> {
    let agent = state.agent()?.clone();
    tauri::async_runtime::spawn_blocking(move || agent.save_usage_source(config, password))
        .await
        .map_err(|_| "无法保存用量来源".to_string())?
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn remove_usage_source(state: State<'_, AgentState>) -> Result<(), String> {
    let agent = state.agent()?.clone();
    tauri::async_runtime::spawn_blocking(move || agent.remove_usage_source())
        .await
        .map_err(|_| "无法移除用量来源".to_string())?
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn choose_application(
    app: tauri::AppHandle,
) -> Result<Option<deskbar_lan::icons::ApplicationMetadata>, String> {
    use tauri_plugin_dialog::DialogExt;
    tauri::async_runtime::spawn_blocking(move || {
        let mut picker = app.dialog().file().set_title("选择要共享的应用");
        #[cfg(target_os = "macos")]
        {
            picker = picker
                .set_directory("/Applications")
                .add_filter("应用", &["app"]);
        }
        #[cfg(target_os = "windows")]
        {
            picker = picker.add_filter("应用", &["exe"]);
        }
        picker
            .blocking_pick_file()
            .map(|p| {
                let path = p.into_path().map_err(|_| "无法读取应用路径".to_string())?;
                deskbar_lan::icons::application_metadata(&path).map_err(|e| e.to_string())
            })
            .transpose()
    })
    .await
    .map_err(|_| "无法打开应用选择器".to_string())?
}

#[tauri::command]
async fn choose_applications(app: tauri::AppHandle) -> Result<Vec<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    tauri::async_runtime::spawn_blocking(move || {
        let mut picker = app.dialog().file().set_title("添加应用");
        #[cfg(target_os = "macos")]
        {
            picker = picker
                .set_directory("/Applications")
                .add_filter("应用", &["app"]);
        }
        #[cfg(target_os = "windows")]
        {
            picker = picker.add_filter("应用", &["exe"]);
        }
        picker
            .blocking_pick_files()
            .unwrap_or_default()
            .into_iter()
            .map(|file| {
                file.into_path()
                    .map(|p| p.to_string_lossy().into_owned())
                    .map_err(|_| "无法读取应用路径".into())
            })
            .collect()
    })
    .await
    .map_err(|_| "无法打开应用选择器".to_string())?
}

#[tauri::command]
async fn import_application(
    path: String,
) -> Result<deskbar_lan::icons::ApplicationMetadata, String> {
    tauri::async_runtime::spawn_blocking(move || {
        deskbar_lan::icons::application_metadata(std::path::Path::new(&path))
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|_| "无法读取应用".to_string())?
}

#[tauri::command]
async fn import_shortcut_icon(path: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        deskbar_lan::icons::import_icon(std::path::Path::new(&path)).map_err(|e| e.to_string())
    })
    .await
    .map_err(|_| "无法读取图标".to_string())?
}

#[tauri::command]
async fn shortcut_recommendations(
    recent: State<'_, std::sync::Arc<recent_apps::RecentApps>>,
    excluded: Vec<String>,
) -> Result<recent_apps::Recommendations, String> {
    let recent = recent.inner().clone();
    tauri::async_runtime::spawn_blocking(move || recent.recommendations(&excluded))
        .await
        .map_err(|_| "无法读取最近应用".to_string())?
}

#[tauri::command]
async fn shortcut_website_info(
    url: String,
) -> Result<deskbar_lan::website_icon::WebsiteInfo, String> {
    deskbar_lan::website_icon::fetch(&url).await
}

#[tauri::command]
async fn open_shortcut(state: State<'_, AgentState>, id: String) -> Result<(), String> {
    let item = state
        .agent()?
        .host
        .lock()
        .unwrap()
        .shortcuts
        .iter()
        .find(|item| item.id == id)
        .cloned()
        .ok_or("入口已移除")?;
    item.validate().map_err(|e| e.to_string())?;
    tauri::async_runtime::spawn_blocking(move || {
        open::that(item.target).map_err(|_| "未能打开，请检查应用或网址".to_string())
    })
    .await
    .map_err(|_| "未能打开入口".to_string())?
}

#[tauri::command]
async fn choose_shortcut_icon(app: tauri::AppHandle) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .set_title("选择入口图标")
            .add_filter(
                "图片",
                &[
                    "png", "jpg", "jpeg", "webp", "icns", "tiff", "gif", "bmp", "ico",
                ],
            )
            .blocking_pick_file()
            .map(|file| {
                let path = file.into_path().map_err(|_| "无法读取图片".to_string())?;
                deskbar_lan::icons::import_icon(&path).map_err(|e| e.to_string())
            })
            .transpose()
    })
    .await
    .map_err(|_| "无法打开图标选择器".to_string())?
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(update::PendingUpdate::default())
        .setup(|app| {
            let directory = app.path().app_data_dir()?;
            let recent = recent_apps::RecentApps::new(directory.join("recent-apps.json"));
            recent_apps::start(app.handle().clone(), recent.clone());
            app.manage(recent);
            let name = hostname::get()?
                .to_string_lossy()
                .trim_end_matches(".local")
                .to_string();
            let agent = tauri::async_runtime::block_on(Agent::start(directory, name))
                .map_err(|e| format!("{e}。请退出 DeskBar 连接助手后重试"));
            app.manage(AgentState(agent));
            let show = MenuItem::with_id(app, "show", "打开 DeskBar 连接助手", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 DeskBar 连接助手", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::new()
                .icon(tauri::include_image!("icons/tray.png"))
                .icon_as_template(true)
                .tooltip("DeskBar 连接助手")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            update::update_check,
            update::update_install,
            agent_status,
            device_workbench,
            save_layout,
            create_invitation,
            cancel_pairing,
            approve_device,
            revoke_device,
            rename_device,
            set_permissions,
            save_shortcut,
            remove_shortcut,
            reorder_shortcuts,
            refresh_sources,
            save_usage_source,
            remove_usage_source,
            choose_application,
            choose_applications,
            import_application,
            import_shortcut_icon,
            shortcut_recommendations,
            shortcut_website_info,
            open_shortcut,
            choose_shortcut_icon
        ])
        .run(tauri::generate_context!())
        .expect("DeskBar 连接助手无法启动");
}
