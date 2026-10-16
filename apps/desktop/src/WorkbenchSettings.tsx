import { useState } from "react";
import {
  call,
  type Device,
  type Permissions,
  type ShortcutConfig,
  type Status,
} from "./api";
type Actions = {
  busy: boolean;
  run: (action: () => Promise<void>) => Promise<void>;
};

export function Sharing({ device, busy, run }: Actions & { device: Device }) {
  return (
    <fieldset className="sharing" disabled={busy}>
      <legend>向这台设备共享</legend>
      {(
        [
          ["sessions", "近期会话"],
          ["quota", "Codex 额度"],
          ["shortcuts", "快捷入口"],
          ["open", "允许在电脑上打开"],
        ] as [keyof Permissions, string][]
      ).map(([key, label]) => (
        <label key={key}>
          <input
            type="checkbox"
            checked={device.permissions[key]}
            onChange={(e) =>
              void run(async () => {
                await call("set_permissions", {
                  id: device.id,
                  permissions: {
                    ...device.permissions,
                    [key]: e.target.checked,
                  },
                });
              })
            }
          />
          {label}
        </label>
      ))}
    </fieldset>
  );
}
export function WorkbenchSettings({
  status,
  busy,
  run,
}: Actions & { status: Status }) {
  const [draft, setDraft] = useState<ShortcutConfig | null>(null);
  const [formError, setFormError] = useState("");
  const [saving, setSaving] = useState(false);
  const [removeId, setRemoveId] = useState<string | null>(null);
  const data = status.workbench;
  async function save() {
    if (!draft || saving) return;
    setSaving(true);
    setFormError("");
    try {
      await call("save_shortcut", {
        item: {
          ...draft,
          name: draft.name.trim(),
          target: draft.target.trim(),
        },
      });
      setDraft(null);
      await run(async () => {});
    } catch (e) {
      setFormError(String(e));
    } finally {
      setSaving(false);
    }
  }
  return (
    <>
      <div className="section-title">
        <h2>工作台内容</h2>
        <button
          className="text-button"
          disabled={busy}
          onClick={() =>
            void run(async () => {
              await call("refresh_sources");
            })
          }
        >
          刷新额度
        </button>
      </div>
      <p>在上方设备卡片中选择共享内容。会话只共享标题、项目名和状态。</p>
      <div className="source-grid">
        {(
          [
            ["codex.sessions", "近期会话"],
            ["codex.quota", "Codex 额度"],
          ] as const
        ).map(([id, label]) => {
          const source = data.sources.find((s) => s.source_id === id);
          const fresh =
            source?.health === "ready" &&
            source.fresh_until > Date.now() / 1000;
          return (
            <section className="source-card" key={id}>
              <h3>{label}</h3>
              <p className={`status-tag${fresh ? " success" : ""}`}>
                {fresh ? "已更新" : source?.message || "正在读取…"}
              </p>
              {id === "codex.sessions" ? (
                <p>
                  近期 {data.sessions.length} 个 / 共 {data.session_total}{" "}
                  个会话
                </p>
              ) : (
                data.quotas.map((q) => (
                  <p key={q.id}>
                    <strong>
                      {q.label} ·{" "}
                      {q.resets_at <= Date.now() / 1000
                        ? "等待刷新"
                        : `剩余 ${Math.round(q.remaining_percent)}%`}
                    </strong>
                    <br />
                    {new Date(q.resets_at * 1000).toLocaleString("zh-CN")} 重置
                  </p>
                ))
              )}
              {source?.observed_at ? (
                <small>
                  上次更新{" "}
                  {new Date(source.observed_at * 1000).toLocaleTimeString(
                    "zh-CN",
                  )}
                </small>
              ) : null}
            </section>
          );
        })}
      </div>
      <div className="section-title">
        <h2>快捷入口</h2>
        <button
          disabled={busy || saving}
          onClick={() => {
            setDraft({
              id: crypto.randomUUID(),
              name: "",
              kind: "url",
              target: "",
            });
            setFormError("");
          }}
        >
          添加入口
        </button>
      </div>
      <p>选择要在电脑上打开的网页或应用，再向设备共享。</p>
      {status.shortcuts.length === 0 && !draft && (
        <p className="source-card">还没有入口，添加一个常用网页或应用吧。</p>
      )}
      {status.shortcuts.map((item) => (
        <article className="shortcut-row" key={item.id}>
          <div>
            <h3>{item.name}</h3>
            <small>
              {item.kind === "app" ? "应用" : "网页"} · {item.target}
            </small>
          </div>
          {removeId === item.id ? (
            <div className="remove-confirm">
              <span>移除这个入口？</span>
              <button
                disabled={busy}
                onClick={() =>
                  void run(async () => {
                    await call("remove_shortcut", { id: item.id });
                    setRemoveId(null);
                  })
                }
              >
                移除
              </button>
              <button className="text-button" onClick={() => setRemoveId(null)}>
                取消
              </button>
            </div>
          ) : (
            <>
              <button
                className="text-button"
                disabled={saving}
                onClick={() => {
                  setDraft({ ...item });
                  setFormError("");
                }}
              >
                编辑
              </button>
              <button
                className="text-button"
                onClick={() => setRemoveId(item.id)}
              >
                移除
              </button>
            </>
          )}
        </article>
      ))}
      {draft && (
        <form
          className="shortcut-form"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <h3>
            {status.shortcuts.some((s) => s.id === draft.id)
              ? "编辑入口"
              : "新入口"}
          </h3>
          <label>
            名称
            <input
              required
              maxLength={64}
              value={draft.name}
              onChange={(e) => setDraft({ ...draft, name: e.target.value })}
            />
          </label>
          <label>
            类型
            <select
              value={draft.kind}
              onChange={(e) =>
                setDraft({ ...draft, kind: e.target.value, target: "" })
              }
            >
              <option value="url">网页</option>
              <option value="app">应用</option>
            </select>
          </label>
          <label>
            {draft.kind === "app" ? "应用的完整路径" : "网址"}
            <input
              required
              maxLength={4096}
              placeholder={
                draft.kind === "app"
                  ? "/Applications/Notes.app"
                  : "https://example.com"
              }
              value={draft.target}
              onChange={(e) => setDraft({ ...draft, target: e.target.value })}
            />
          </label>
          {draft.kind === "app" && (
            <button
              type="button"
              disabled={saving}
              onClick={async () => {
                setFormError("");
                try {
                  const target = await call<string | null>(
                    "choose_application",
                  );
                  if (target)
                    setDraft({
                      ...draft,
                      target,
                      name:
                        draft.name ||
                        target
                          .split(/[\\/]/)
                          .pop()!
                          .replace(/\.app$/i, ""),
                    });
                } catch (e) {
                  setFormError(String(e));
                }
              }}
            >
              选择应用
            </button>
          )}
          {draft.kind === "app" && (
            <p>选择电脑上的应用即可；路径只保存在这台电脑。</p>
          )}
          {formError && (
            <p role="alert" className="notice error">
              {formError}
            </p>
          )}
          <div className="modal-actions">
            <button className="primary" disabled={saving}>
              {saving ? "保存中…" : "保存入口"}
            </button>
            <button
              type="button"
              disabled={saving}
              onClick={() => setDraft(null)}
            >
              取消
            </button>
          </div>
        </form>
      )}
    </>
  );
}
