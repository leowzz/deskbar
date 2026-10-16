#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use desklet_lan::{Agent, AgentStatus, PairingInvitation};
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
fn set_permissions(
    state: State<AgentState>,
    id: String,
    permissions: desklet_host::workbench::Permissions,
) -> Result<(), String> {
    state
        .agent()?
        .set_permissions(&id, permissions)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn save_shortcut(
    state: State<'_, AgentState>,
    item: desklet_host::workbench::ShortcutConfig,
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
fn refresh_sources(state: State<AgentState>) -> Result<(), String> {
    state.agent()?.refresh_sources();
    Ok(())
}

#[tauri::command]
async fn save_usage_source(
    state: State<'_, AgentState>,
    config: desklet_host::usage::UsageConfig,
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
) -> Result<Option<desklet_lan::icons::ApplicationMetadata>, String> {
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
                desklet_lan::icons::application_metadata(&path).map_err(|e| e.to_string())
            })
            .transpose()
    })
    .await
    .map_err(|_| "无法打开应用选择器".to_string())?
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
                desklet_lan::icons::import_icon(&path).map_err(|e| e.to_string())
            })
            .transpose()
    })
    .await
    .map_err(|_| "无法打开图标选择器".to_string())?
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let directory = app.path().app_data_dir()?;
            let name = hostname::get()?
                .to_string_lossy()
                .trim_end_matches(".local")
                .to_string();
            let agent = tauri::async_runtime::block_on(Agent::start(directory, name))
                .map_err(|e| format!("{e}。请退出 Desklet 连接助手后重试"));
            app.manage(AgentState(agent));
            let show = MenuItem::with_id(app, "show", "打开 Desklet 连接助手", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Desklet 连接助手", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            // Small monochrome screen, generated in memory; no icon asset pipeline.
            let mut rgba = vec![0u8; 22 * 22 * 4];
            for y in 0..22 {
                for x in 0..22 {
                    if ((3..=18).contains(&x)
                        && (3..=15).contains(&y)
                        && (x <= 4 || x >= 17 || y <= 4 || y >= 14))
                        || ((9..=12).contains(&x) && (16..=18).contains(&y))
                        || ((6..=15).contains(&x) && y == 19)
                    {
                        rgba[(y * 22 + x) * 4 + 3] = 255;
                    }
                }
            }
            TrayIconBuilder::new()
                .icon(tauri::image::Image::new_owned(rgba, 22, 22))
                .icon_as_template(true)
                .tooltip("Desklet 连接助手")
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
            agent_status,
            create_invitation,
            cancel_pairing,
            approve_device,
            revoke_device,
            set_permissions,
            save_shortcut,
            remove_shortcut,
            refresh_sources,
            save_usage_source,
            remove_usage_source,
            choose_application,
            choose_shortcut_icon
        ])
        .run(tauri::generate_context!())
        .expect("Desklet 连接助手无法启动");
}
