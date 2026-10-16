//! Explicitly launched test fixture. Never linked into the desktop application.
//! Creates a temporary identity, auto-approves one device, then revokes it.
use desklet_host::{now, Host};
use desklet_lan::{Agent, Identity};
use std::{fs, path::PathBuf, time::Duration};

#[tokio::test]
#[ignore = "requires a running Android integration test; see tests/README.md"]
async fn android_connection_fixture() {
    let directory = PathBuf::from(
        std::env::var("DESKLET_FIXTURE_DIR").expect("Set a private fixture directory"),
    );
    fs::create_dir_all(&directory).unwrap();
    let host = Host::load(directory.join("host"), "Desklet 连接测试".into()).unwrap();
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
            // Allows Android to verify persisted credentials and reconnect first.
            tokio::time::sleep(Duration::from_secs(15)).await;
            agent.revoke(&pending.id).unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
            assert!(agent.status().devices.is_empty());
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("Android did not request pairing before the invitation expired");
}
