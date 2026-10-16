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

fn main() {
    tauri::Builder::default()
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
            revoke_device
        ])
        .run(tauri::generate_context!())
        .expect("Desklet 连接助手无法启动");
}
