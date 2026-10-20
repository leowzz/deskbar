//! Pairing must remain reachable while the main webview is hidden or on another Space.
use deskbar_host::Host;
use deskbar_lan::Agent;
use objc2::{rc::Retained, MainThreadMarker};
use objc2_app_kit::{
    NSAlert, NSAlertFirstButtonReturn, NSApplication, NSModalPanelWindowLevel,
    NSModalResponseAbort, NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_foundation::NSString;
use std::{
    cell::RefCell,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Default)]
struct PromptState {
    active: Option<(String, Retained<NSAlert>)>,
    error: Option<(String, String)>,
}

thread_local! {
    static PROMPT: RefCell<PromptState> = RefCell::new(PromptState::default());
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// Check and cancel under the same lock: dismissing an expired alert must never
// cancel a newer request (or destroy an already approved, unclaimed pairing).
fn reject_current(host: &mut Host, id: &str, time: u64) {
    if host.pending(time).is_some_and(|request| request.id == id) {
        host.cancel_pairing();
    }
}

pub fn start(app: tauri::AppHandle, agent: Agent) {
    tauri::async_runtime::spawn(async move {
        loop {
            let agent = agent.clone();
            if app.run_on_main_thread(move || sync(&agent)).is_err() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    });
}

fn sync(agent: &Agent) {
    let mtm = MainThreadMarker::new().expect("pairing prompt runs on the main thread");
    let pending = agent.host.lock().unwrap().pending(now());
    let already_open = PROMPT.with_borrow(|state| {
        if let Some((id, alert)) = &state.active {
            if pending.as_ref().is_none_or(|request| request.id != *id) {
                NSApplication::sharedApplication(mtm).stopModalWithCode(NSModalResponseAbort);
                alert.window().orderOut(None);
            }
            true
        } else {
            false
        }
    });
    if already_open {
        return;
    }
    let Some(request) = pending else {
        return;
    };

    let alert = NSAlert::new(mtm);
    alert.setMessageText(&NSString::from_str("允许连接这台设备？"));
    let details = match request.existing_device_name.as_deref() {
        Some(name) => format!("将重新连接「{name}」，保留原有名称、共享权限和屏幕布局。只确认你正在操作的设备。"),
        None => "只确认你正在操作的设备。连接后，请在设备卡片中选择共享内容；你随时可以修改权限或移除设备。".into(),
    };
    let error = PROMPT
        .with_borrow_mut(|state| state.error.take())
        .filter(|(id, _)| id == &request.id)
        .map(|(_, error)| format!("\n\n未能连接：{error}。请重试。"))
        .unwrap_or_default();
    alert.setInformativeText(&NSString::from_str(&format!(
        "{}\n\n{details}{error}",
        request.name
    )));
    alert
        .addButtonWithTitle(&NSString::from_str("允许连接"))
        .setKeyEquivalent(&NSString::from_str("\r"));
    alert
        .addButtonWithTitle(&NSString::from_str("拒绝"))
        .setKeyEquivalent(&NSString::from_str("\u{1b}"));

    let window = alert.window(); // AppKit supplies an NSPanel for NSAlert.
    window.setTitle(&NSString::from_str("DeskBar 连接助手"));
    window.setStyleMask(window.styleMask() | NSWindowStyleMask::NonactivatingPanel);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary,
    );
    window.setLevel(NSModalPanelWindowLevel);
    window.setHidesOnDeactivate(false);
    PROMPT.with_borrow_mut(|state| state.active = Some((request.id.clone(), alert.clone())));
    // Do not activate the app: that would switch to the main window's Space.
    window.orderFrontRegardless();
    let response = alert.runModal();
    window.orderOut(None);
    PROMPT.with_borrow_mut(|state| state.active = None);
    if response == NSAlertFirstButtonReturn {
        if let Err(error) = agent.approve(&request.id) {
            PROMPT.with_borrow_mut(|state| state.error = Some((request.id, error.to_string())));
        }
    } else if response != NSModalResponseAbort {
        reject_current(&mut agent.host.lock().unwrap(), &request.id, now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dismissing_old_request_preserves_new_request_and_approved_claim() {
        let directory = tempfile::tempdir().unwrap();
        let mut host = Host::load(directory.path().into(), "电脑".into()).unwrap();
        let invite = host.invite(100);
        let first = host
            .request_pairing(
                &invite.session_id,
                &invite.secret,
                &"a".repeat(43),
                "屏幕",
                101,
            )
            .unwrap();
        reject_current(&mut host, &first.id, 102);
        assert!(host.pending(102).is_none());

        let invite = host.invite(103);
        let second = host
            .request_pairing(
                &invite.session_id,
                &invite.secret,
                &"b".repeat(43),
                "另一台屏幕",
                104,
            )
            .unwrap();
        reject_current(&mut host, &first.id, 105);
        assert_eq!(host.pending(105).unwrap().id, second.id);
        host.approve(&second.id, 106).unwrap();
        reject_current(&mut host, &second.id, 107);
        assert!(host.claim(&second.id, &"b".repeat(43), 108).is_ok());
    }
}
