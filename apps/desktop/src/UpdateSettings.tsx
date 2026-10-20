import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";

export function UpdateSettings() {
  const [current, setCurrent] = useState("");
  const [version, setVersion] = useState<string | null>(null);
  const [phase, setPhase] = useState<"idle" | "checking" | "installing">(
    "idle",
  );
  const [message, setMessage] = useState("");
  const [error, setError] = useState(false);

  useEffect(() => {
    void getVersion()
      .then(setCurrent)
      .catch(() => {});
  }, []);

  async function check() {
    setPhase("checking");
    setVersion(null);
    setMessage("");
    setError(false);
    try {
      const offer = await invoke<{
        currentVersion: string;
        version: string | null;
      }>("update_check");
      setCurrent(offer.currentVersion);
      setVersion(offer.version);
      setMessage(
        offer.version ? `发现新版本 ${offer.version}` : "已是最新版本",
      );
    } catch (error) {
      setError(true);
      setMessage(String(error));
    } finally {
      setPhase("idle");
    }
  }

  async function install() {
    setPhase("installing");
    setMessage("正在下载并安装，完成后将重新启动…");
    setError(false);
    try {
      await invoke("update_install");
    } catch (error) {
      setVersion(null);
      setError(true);
      setMessage(String(error));
      setPhase("idle");
    }
  }

  return (
    <section className="settings-panel" aria-labelledby="update-title">
      <h2 id="update-title">软件更新</h2>
      {current && <p>当前版本 {current}</p>}
      <p className={error ? "notice error" : ""} role="status">
        {message}
      </p>
      <button disabled={phase !== "idle"} onClick={version ? install : check}>
        {phase === "checking"
          ? "正在检查…"
          : phase === "installing"
            ? "正在更新…"
            : version
              ? "安装并重启"
              : "检查更新"}
      </button>
    </section>
  );
}
