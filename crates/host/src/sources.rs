//! Read-only local Codex adapters. No credentials, transcript or local paths on the wire.
use crate::{
    digest,
    workbench::{Quota, Session},
};
use anyhow::{ensure, Context, Result};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

pub fn codex_home() -> PathBuf {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .unwrap_or_default(),
            )
            .join(".codex")
        })
}
fn newest(home: &Path, prefix: &str) -> Result<PathBuf> {
    let mut files: Vec<_> = std::fs::read_dir(home)
        .context("找不到 Codex 数据，请先打开 Codex")?
        .filter_map(Result::ok)
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|s| s.starts_with(prefix) && s.ends_with(".sqlite"))
        })
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files
        .first()
        .map(|x| x.1.clone())
        .context("Codex 数据尚未生成，请先打开 Codex")
}
fn database(path: &Path) -> Result<Connection> {
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("无法读取 Codex 数据")?;
    db.busy_timeout(Duration::from_millis(500))?;
    Ok(db)
}
fn bounded(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
}
pub fn sessions(home: &Path) -> Result<(Vec<Session>, usize)> {
    let mut db = database(&newest(home, "state_")?)?;
    let tx = db.transaction()?;
    let columns: Vec<String> = tx
        .prepare("PRAGMA table_info(threads)")?
        .query_map([], |r| r.get(1))?
        .collect::<rusqlite::Result<_>>()?;
    let title = if columns.iter().any(|c| c == "name") {
        "COALESCE(NULLIF(name,''),NULLIF(title,''),'未命名会话')"
    } else {
        "COALESCE(NULLIF(title,''),'未命名会话')"
    };
    let updated = if columns.iter().any(|c| c == "updated_at_ms") {
        "COALESCE(updated_at_ms,updated_at*1000)/1000"
    } else {
        "updated_at"
    };
    let edges: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='thread_spawn_edges')",
        [],
        |r| r.get(0),
    )?;
    let filter = format!(
        "archived=0 AND source NOT LIKE '%subagent%' {}",
        if edges {
            "AND NOT EXISTS(SELECT 1 FROM thread_spawn_edges WHERE child_thread_id=threads.id)"
        } else {
            ""
        }
    );
    let total: usize = tx.query_row(
        &format!("SELECT count(*) FROM threads WHERE {filter}"),
        [],
        |r| r.get(0),
    )?;
    let history = newest(home, "thread_history_").and_then(|p| database(&p));
    let mut stmt = tx.prepare(&format!("SELECT id,{title},cwd,{updated} FROM threads WHERE {filter} ORDER BY {updated} DESC,id LIMIT 40")).context("Codex 会话格式不兼容，请更新连接助手")?;
    let sessions = stmt.query_map([], |r| {
        let id: String = r.get(0)?;
        let title: String = r.get(1)?;
        let cwd: String = r.get(2)?;
        let updated_at = r.get::<_,i64>(3)?.max(0) as u64;
        let status = history.as_ref().ok().and_then(|h| h.query_row("SELECT status FROM thread_turns WHERE thread_id=?1 ORDER BY started_at DESC,rowid DESC LIMIT 1", [&id], |r| r.get::<_,String>(0)).ok()).map(|s| match s.to_ascii_lowercase().replace('_', "").as_str() { "inprogress" | "running" | "started" => "running", "completed" | "complete" => "completed", "failed" => "failed", "interrupted" | "cancelled" | "aborted" => "interrupted", _ => "unknown" }.to_string()).unwrap_or_else(|| "unknown".into());
        Ok(Session { version: digest(&format!("{id}:{updated_at}:{title}:{status}")), session_id: id, title: bounded(&title,192), project: bounded(cwd.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or(""),96), status, updated_at })
    })?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok((sessions, total))
}
pub fn parse_quotas(value: &Value, time: u64) -> Result<Vec<Quota>> {
    let bucket = if value
        .get("rateLimitsByLimitId")
        .is_some_and(|v| !v.is_null())
    {
        &value["rateLimitsByLimitId"]["codex"]
    } else {
        &value["rateLimits"]
    };
    ensure!(
        !bucket.is_null()
            && !bucket["limitId"]
                .as_str()
                .is_some_and(|s| !s.is_empty() && s != "codex"),
        "Codex 额度暂不可用"
    );
    let mut result = Vec::new();
    for id in ["primary", "secondary"] {
        let w = &bucket[id];
        if w.is_null() {
            continue;
        }
        let used = w["usedPercent"]
            .as_f64()
            .filter(|n| n.is_finite() && *n >= 0.)
            .context("额度格式不正确")?;
        let minutes = w["windowDurationMins"]
            .as_u64()
            .filter(|n| *n > 0)
            .context("额度周期不可用")?;
        let reset = w["resetsAt"]
            .as_u64()
            .filter(|n| *n > time)
            .context("额度已到重置时间，等待刷新")?;
        result.push(Quota {
            id: id.into(),
            label: match minutes {
                300 => "5 小时额度".into(),
                10080 => "每周额度".into(),
                n => format!("{n} 分钟额度"),
            },
            remaining_percent: (100. - used).clamp(0., 100.),
            resets_at: reset,
            window_minutes: minutes,
        });
    }
    ensure!(
        !result.is_empty(),
        "当前账号没有可用额度，请在 Codex 中确认登录状态"
    );
    Ok(result)
}
pub async fn quotas() -> Result<Vec<Quota>> {
    let bundled = Path::new("/Applications/Codex.app/Contents/Resources/codex");
    let binary = if bundled.is_file() {
        bundled.to_path_buf()
    } else {
        PathBuf::from("codex")
    };
    let mut child = tokio::process::Command::new(binary)
        .args(["app-server", "--listen", "stdio://"])
        .env("CODEX_HOME", codex_home())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("找不到 Codex 程序，请安装 Codex 后重试")?;
    let result = tokio::time::timeout(Duration::from_secs(15), async {
        let mut input = child.stdin.take().context("无法连接 Codex")?;
        let mut output = BufReader::new(child.stdout.take().context("无法连接 Codex")?);
        input.write_all(b"{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"desklet\",\"title\":\"Desklet\",\"version\":\"0.1.0\"}}}\n").await?;
        let mut initialized = false;
        loop {
            let mut bytes = Vec::new();
            let n = (&mut output).take(1048577).read_until(b'\n', &mut bytes).await?;
            ensure!(n > 0 && n <= 1048576, "无法读取 Codex 额度");
            let value: Value = serde_json::from_slice(&bytes)?;
            let id = value["id"].as_i64().unwrap_or(0);
            if id != 1 && id != 2 { continue; }
            ensure!(value["error"].is_null(), "请在 Codex 中登录后重试");
            if id == 2 { return parse_quotas(&value["result"], crate::now()); }
            if !initialized { initialized = true; input.write_all(b"{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\"}\n").await?; }
        }
    }).await.context("读取 Codex 额度超时")?;
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quota_windows_use_provider_values_and_never_guess_reset() {
        let value = serde_json::json!({"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":23.5,"resetsAt":200},"secondary":{"windowDurationMins":10080,"usedPercent":110,"resetsAt":300}}}});
        let q = parse_quotas(&value, 100).unwrap();
        assert_eq!(q[0].remaining_percent, 76.5);
        assert_eq!(q[1].remaining_percent, 0.);
        assert!(parse_quotas(&value, 200).is_err());
        assert!(parse_quotas(&serde_json::json!({"rateLimitsByLimitId":{},"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":0,"resetsAt":200}}}),100).is_err());
    }
    #[test]
    fn sessions_are_read_only_bounded_and_exclude_archives_and_children() {
        let dir = tempfile::tempdir().unwrap();
        let db = Connection::open(dir.path().join("state_5.sqlite")).unwrap();
        db.execute_batch("CREATE TABLE threads(id TEXT, name TEXT,title TEXT,cwd TEXT,source TEXT,archived INTEGER,updated_at INTEGER,updated_at_ms INTEGER); CREATE TABLE thread_spawn_edges(child_thread_id TEXT);").unwrap();
        for (id, source, archive) in [
            ("main", "cli", 0),
            ("child", "{\"subagent\":{}}", 0),
            ("archived", "cli", 1),
            ("edge", "cli", 0),
        ] {
            db.execute(
                "INSERT INTO threads VALUES(?1,'','标题','/private/work/project',?2,?3,100,100000)",
                rusqlite::params![id, source, archive],
            )
            .unwrap();
        }
        db.execute("INSERT INTO thread_spawn_edges VALUES('edge')", [])
            .unwrap();
        let history = Connection::open(dir.path().join("thread_history_1.sqlite")).unwrap();
        history.execute_batch("CREATE TABLE thread_turns(thread_id TEXT,status TEXT,started_at INTEGER); INSERT INTO thread_turns VALUES('main','completed',100); INSERT INTO thread_turns VALUES('main','in_progress',200);").unwrap();
        let (items, total) = sessions(dir.path()).unwrap();
        assert_eq!(total, 1);
        assert_eq!(items[0].title, "标题");
        assert_eq!(items[0].project, "project");
        assert_eq!(items[0].status, "running");
        assert!(!serde_json::to_string(&items).unwrap().contains("/private"));
        assert_eq!(
            db.query_row("SELECT count(*) FROM threads", [], |r| r.get::<_, usize>(0))
                .unwrap(),
            4
        );
    }
    #[tokio::test]
    #[ignore = "read-only smoke test using this computer's Codex account"]
    async fn live_local_sources() {
        let (items, total) = sessions(&codex_home()).unwrap();
        assert!(items.len() <= 40);
        let quotas = quotas().await.unwrap();
        println!(
            "Local Codex: {} visible / {total} sessions, {} quota windows",
            items.len(),
            quotas.len()
        );
    }
}
