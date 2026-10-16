//! Explicitly launched test fixture. Never linked into the desktop application.
//! Creates a temporary identity, auto-approves one device, then revokes it.
use desklet_host::{
    now,
    workbench::{Permissions, Quota, Session, ShortcutConfig},
    Host,
};
use desklet_lan::{Agent, Identity};
use std::{fs, path::PathBuf, time::Duration};

#[tokio::test]
#[ignore = "requires a running Android integration test; see tests/README.md"]
async fn android_connection_fixture() {
    let directory = PathBuf::from(
        std::env::var("DESKLET_FIXTURE_DIR").expect("Set a private fixture directory"),
    );
    fs::create_dir_all(&directory).unwrap();
    let mut host = Host::load(directory.join("host"), "Desklet 连接测试".into()).unwrap();
    host.workbench.sessions = vec![Session {
        session_id: "00000000-0000-4000-8000-000000000001".into(),
        version: "fixture-version".into(),
        title: "验证工作台连接".into(),
        project: "Desklet".into(),
        status: "running".into(),
        updated_at: now(),
    }];
    host.workbench.session_total = 1;
    host.workbench.quotas = vec![Quota {
        id: "weekly".into(),
        label: "每周额度".into(),
        remaining_percent: 42.,
        resets_at: now() + 180,
        window_minutes: 10080,
    }];
    host.workbench
        .observed("codex.sessions", Ok(()), now(), 180);
    host.workbench.observed("codex.quota", Ok(()), now(), 180);
    host.workbench.api_usage = vec![desklet_host::usage::parse_usage(
        &serde_json::json!({"today_actual_cost":1.25,"today_tokens":1234,"tpm":42}),
        "Asia/Shanghai",
        now(),
    )
    .unwrap()];
    host.workbench.observed("sub2api.usage", Ok(()), now(), 180);
    host.save_shortcut(ShortcutConfig {
        id: "00000000-0000-4000-8000-000000000002".into(),
        name: "测试入口".into(),
        kind: "url".into(),
        target: "https://example.com".into(),
        icon_png: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMwsAv6D8IMMAYAOewG/V2y8+cAAAAASUVORK5CYII=".into(),
    })
    .unwrap();
    let identity = Identity::from_key(rcgen::KeyPair::generate().unwrap().serialize_pem()).unwrap();
    let agent = Agent::with_identity(host, identity, 0).await.unwrap();
    let invitation = agent.invite().unwrap();
    let mut uri = url::Url::parse(&invitation.uri).unwrap();
    let fields: Vec<_> = uri
        .query_pairs()
        .filter(|(key, _)| key != "endpoint")
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    uri.query_pairs_mut()
        .clear()
        .extend_pairs(fields)
        .append_pair("endpoint", &format!("https://10.0.2.2:{}", agent.port));
    let path = directory.join("invite.json");
    fs::write(
        &path,
        serde_json::json!({"DESKLET_INVITE":uri.as_str()}).to_string(),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let deadline = now() + 115;
    while now() < deadline {
        if let Some(pending) = agent.status().pending {
            agent.approve(&pending.id).unwrap();
            agent
                .set_permissions(
                    &pending.id,
                    Permissions {
                        sessions: true,
                        quota: true,
                        api_usage: true,
                        shortcuts: true,
                        open: true,
                    },
                )
                .unwrap();
            // Allows Android to verify persisted credentials and reconnect first.
            tokio::time::sleep(Duration::from_secs(8)).await;
            agent
                .set_permissions(&pending.id, Permissions::default())
                .unwrap();
            tokio::time::sleep(Duration::from_secs(8)).await;
            agent.revoke(&pending.id).unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
            assert!(agent.status().devices.is_empty());
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("Android did not request pairing before the invitation expired");
}
