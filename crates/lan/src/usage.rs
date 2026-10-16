use super::{credentials::credential_account, Agent};
use anyhow::{ensure, Context, Result};
use deskbar_host::{
    now,
    usage::{Error, Source, UsageConfig},
};
use std::{sync::atomic::Ordering, time::Duration};

impl Agent {
    fn usage_source_snapshot(
        &self,
        generation: u64,
        expected: &UsageConfig,
        read: impl FnOnce(&str) -> Result<Option<String>>,
    ) -> Result<Option<Source>> {
        // Account updates hold the same lock while replacing the local secret.
        // Read the config and password together so a new password can never be
        // combined with a previously captured account or endpoint.
        let host = self.host.lock().unwrap();
        if self.usage_generation.load(Ordering::SeqCst) != generation
            || host.usage_config.as_ref() != Some(expected)
        {
            return Ok(None);
        }
        let password = read(&host.id)?.context("请在连接助手中重新填写用量账号密码")?;
        Source::new(expected.clone(), password).map(Some)
    }
    pub fn save_usage_source(&self, config: UsageConfig, password: String) -> Result<()> {
        config.validate()?;
        ensure!(password.len() <= 4096, "密码过长");
        let mut host = self.host.lock().unwrap();
        let previous_config = host.usage_config.clone();
        let account = credential_account(&host.id, &config);
        let mut credentials = self.credentials.lock().unwrap();
        let old = credentials.password(&account);
        if password.is_empty() {
            ensure!(
                host.usage_config
                    .as_ref()
                    .is_some_and(|c| c.base_url == config.base_url && c.email == config.email)
                    && old.as_ref().is_some_and(|v| !v.is_empty()),
                "首次设置或更换账号时请输入密码"
            );
        } else {
            credentials.set_password(&account, Some(&password))?;
        }
        if let Err(e) = host.set_usage_config(Some(config.clone())) {
            if !password.is_empty() {
                credentials.set_password(&account, old.as_deref())?;
            }
            return Err(e);
        }
        // The old config always points at its own secret, including if the
        // process exits between writing a new secret and committing the YAML.
        // A crash after committing may leave an unused secret, never a secret
        // attached to the wrong endpoint. Remove it on the normal success path.
        if let Some(previous) = previous_config {
            if credential_account(&host.id, &previous) != credential_account(&host.id, &config) {
                let _ = credentials.set_password(&credential_account(&host.id, &previous), None);
            }
        }
        self.usage_generation.fetch_add(1, Ordering::SeqCst);
        drop(host);
        self.changed.send_modify(|r| *r += 1);
        self.usage_refresh.notify_one();
        Ok(())
    }
    pub fn remove_usage_source(&self) -> Result<()> {
        let mut host = self.host.lock().unwrap();
        let Some(config) = host.usage_config.as_ref() else {
            return Ok(());
        };
        let account = credential_account(&host.id, config);
        let mut credentials = self.credentials.lock().unwrap();
        let old = credentials.password(&account);
        if old.is_some() {
            credentials.set_password(&account, None)?;
        }
        if let Err(e) = host.set_usage_config(None) {
            if old.is_some() {
                credentials.set_password(&account, old.as_deref())?;
            }
            return Err(e);
        }
        self.usage_generation.fetch_add(1, Ordering::SeqCst);
        drop(host);
        self.changed.send_modify(|r| *r += 1);
        self.usage_refresh.notify_one();
        Ok(())
    }
    pub(super) fn start_usage(&self) {
        let agent = self.clone();
        tokio::spawn(async move {
            let mut source: Option<Source> = None;
            let mut loaded_generation = u64::MAX;
            loop {
                let (config, generation) = {
                    let host = agent.host.lock().unwrap();
                    (
                        host.usage_config.clone(),
                        agent.usage_generation.load(Ordering::SeqCst),
                    )
                };
                let Some(config) = config else {
                    source = None;
                    loaded_generation = u64::MAX;
                    agent.usage_refresh.notified().await;
                    continue;
                };
                let result = if source.is_none() || loaded_generation != generation {
                    let loading = agent.clone();
                    let loaded = tokio::task::spawn_blocking(move || {
                        loading.usage_source_snapshot(generation, &config, |id| {
                            Ok(loading
                                .credentials
                                .lock()
                                .unwrap()
                                .password(&credential_account(id, &config)))
                        })
                    })
                    .await;
                    loaded_generation = generation;
                    match loaded {
                        Ok(Ok(Some(value))) => {
                            source = Some(value);
                            Ok(())
                        }
                        Ok(Ok(None)) => continue,
                        Ok(Err(error)) => {
                            source = None;
                            Err(error)
                        }
                        _ => {
                            source = None;
                            Err(anyhow::anyhow!("无法读取用量账号，请在设置中重新保存账号"))
                        }
                    }
                } else {
                    Ok(())
                };
                let mut delay = Duration::from_secs(60);
                let mut rate_limited = false;
                // Reconfiguration may have completed while the blocking credential
                // task returned. Discard it before making any network request.
                if agent.usage_generation.load(Ordering::SeqCst) != generation {
                    continue;
                }
                let result = if result.is_ok() {
                    match source.as_mut().unwrap().fetch(now()).await {
                        Ok(value) => Ok(value),
                        Err(e) => {
                            if let Error::RateLimited(d) = &e {
                                delay = *d;
                                rate_limited = true;
                            }
                            Err(anyhow::anyhow!(e.message()))
                        }
                    }
                } else {
                    Err(result.unwrap_err())
                };
                {
                    let mut host = agent.host.lock().unwrap();
                    // Ignore an in-flight response after changing or removing the account.
                    if agent.usage_generation.load(Ordering::SeqCst) != generation {
                        continue;
                    }
                    let health = result.map(|value| {
                        host.workbench.api_usage = vec![value];
                    });
                    host.workbench.observed("sub2api.usage", health, now(), 180);
                    host.revision += 1;
                }
                agent.changed.send_modify(|r| *r += 1);
                // Respect server backoff even if the user repeatedly refreshes. Reconfiguration
                // interrupts polling, but never causes an old response to be published.
                let deadline = tokio::time::Instant::now() + delay;
                loop {
                    tokio::select! {
                        _ = tokio::time::sleep_until(deadline) => break,
                        _ = agent.usage_refresh.notified() => {
                            if !rate_limited || agent.usage_generation.load(Ordering::SeqCst) != generation { break; }
                        }
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn local_agent(path: &std::path::Path) -> Agent {
        let host = deskbar_host::Host::load(path.into(), "fixture".into()).unwrap();
        let identity =
            super::super::Identity::from_key(rcgen::KeyPair::generate().unwrap().serialize_pem())
                .unwrap();
        Agent::with_identity(host, identity, 0).await.unwrap()
    }

    fn config() -> UsageConfig {
        UsageConfig {
            base_url: "https://usage.example.com".into(),
            email: "fixture@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        }
    }

    fn saved_password(agent: &Agent, config: &UsageConfig) -> Option<String> {
        let host = agent.host.lock().unwrap();
        super::super::Credentials::load(&host, true)
            .unwrap()
            .password(&credential_account(&host.id, config))
    }

    #[tokio::test]
    async fn local_account_save_keep_replace_and_remove_persist_without_exposing_passwords() {
        let dir = tempfile::tempdir().unwrap();
        let agent = local_agent(dir.path()).await;
        let old = config();
        assert!(agent.save_usage_source(old.clone(), String::new()).is_err());
        agent
            .save_usage_source(old.clone(), "old-password".into())
            .unwrap();
        assert_eq!(
            saved_password(&agent, &old).as_deref(),
            Some("old-password")
        );
        let mut next = old.clone();
        next.timezone = "UTC".into();
        agent
            .save_usage_source(next.clone(), String::new())
            .unwrap();
        assert_eq!(
            saved_password(&agent, &next).as_deref(),
            Some("old-password")
        );
        next.email = "another@example.com".into();
        assert!(agent
            .save_usage_source(next.clone(), String::new())
            .is_err());
        agent
            .save_usage_source(next.clone(), "new-password".into())
            .unwrap();
        assert!(saved_password(&agent, &old).is_none());
        assert_eq!(
            saved_password(&agent, &next).as_deref(),
            Some("new-password")
        );
        let status = serde_json::to_string(&agent.status()).unwrap();
        assert!(!status.contains("new-password"));
        assert!(!status.contains("PRIVATE KEY"));
        let host_config = std::fs::read_to_string(dir.path().join("host.yaml")).unwrap();
        assert!(!host_config.contains("new-password"));
        agent.remove_usage_source().unwrap();
        assert!(agent.status().usage_config.is_none());
        assert!(saved_password(&agent, &next).is_none());
    }

    #[tokio::test]
    async fn failed_config_commit_restores_local_password_and_account() {
        let dir = tempfile::tempdir().unwrap();
        let agent = local_agent(dir.path()).await;
        let old = config();
        agent
            .save_usage_source(old.clone(), "old-password".into())
            .unwrap();
        let generation = agent.usage_generation.load(Ordering::SeqCst);
        // Host's atomic configuration replacement cannot create its temp file.
        std::fs::create_dir(dir.path().join("host.yaml.tmp")).unwrap();
        assert!(agent
            .save_usage_source(old.clone(), "replacement-password".into())
            .is_err());
        assert_eq!(
            saved_password(&agent, &old).as_deref(),
            Some("old-password")
        );
        let mut next = old.clone();
        next.base_url = "https://another.example.com".into();
        assert!(agent
            .save_usage_source(next.clone(), "new-password".into())
            .is_err());
        assert!(saved_password(&agent, &next).is_none());
        assert!(agent.remove_usage_source().is_err());
        assert_eq!(agent.status().usage_config, Some(old.clone()));
        assert_eq!(
            saved_password(&agent, &old).as_deref(),
            Some("old-password")
        );
        assert_eq!(agent.usage_generation.load(Ordering::SeqCst), generation);
    }

    #[test]
    fn secret_identity_survives_config_commit_interruptions() {
        let old = UsageConfig {
            base_url: "https://old.example.com".into(),
            email: "a@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        };
        let mut next = old.clone();
        let old_key = credential_account("host", &old);
        next.base_url = "https://new.example.com".into();
        let new_key = credential_account("host", &next);
        assert_ne!(old_key, new_key);
        // Simulate a new credential write before the YAML switches accounts.
        let secrets = std::collections::HashMap::from([
            (old_key.clone(), "old-password"),
            (new_key, "new-password"),
        ]);
        assert_eq!(secrets[&credential_account("host", &old)], "old-password");
        assert_eq!(secrets[&credential_account("host", &next)], "new-password");
        next = old.clone();
        next.email = "b@example.com".into();
        assert_ne!(credential_account("host", &next), old_key);
        next = old.clone();
        next.timezone = "UTC".into();
        assert_eq!(credential_account("host", &next), old_key);
        assert_ne!(credential_account("other-host", &old), old_key);
    }

    #[tokio::test]
    async fn account_and_secret_are_read_as_one_generation() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = deskbar_host::Host::load(dir.path().into(), "fixture".into()).unwrap();
        let old = UsageConfig {
            base_url: "https://old.example.com".into(),
            email: "old@example.com".into(),
            timezone: "Asia/Shanghai".into(),
        };
        host.set_usage_config(Some(old.clone())).unwrap();
        let identity =
            super::super::Identity::from_key(rcgen::KeyPair::generate().unwrap().serialize_pem())
                .unwrap();
        let agent = Agent::with_identity(host, identity, 0).await.unwrap();
        let source = agent
            .usage_source_snapshot(0, &old, |_| {
                // A concurrent account update cannot replace the password/config
                // while this reader is retrieving the matching secret.
                assert!(agent.host.try_lock().is_err());
                Ok(Some("fixture-old-password".into()))
            })
            .unwrap();
        assert!(source.is_some());
        {
            let mut host = agent.host.lock().unwrap();
            let mut next = old.clone();
            next.base_url = "https://new.example.com".into();
            host.set_usage_config(Some(next)).unwrap();
            agent.usage_generation.fetch_add(1, Ordering::SeqCst);
        }
        let stale = agent
            .usage_source_snapshot(0, &old, |_| {
                panic!("a stale config must never retrieve the replacement secret")
            })
            .unwrap();
        assert!(stale.is_none());
        // Even a config mismatch without a version change refuses the secret.
        assert!(agent
            .usage_source_snapshot(1, &old, |_| panic!("wrong account"))
            .unwrap()
            .is_none());
    }
}
