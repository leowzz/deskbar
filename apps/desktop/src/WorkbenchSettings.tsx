import { useEffect, useRef, useState, type FormEvent } from "react";
import { ShortcutCatalog, ShortcutIcon } from "./ShortcutCatalog";
import {
  call,
  type Device,
  type ApplicationMetadata,
  type Permissions,
  type ShortcutConfig,
  type Status,
  type UsageConfig,
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
          ["api_usage", "API 用量"],
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
          <span>{label}</span>
        </label>
      ))}
    </fieldset>
  );
}
export function WorkbenchSettings({
  status,
  busy,
  run,
  mode,
}: Actions & { status: Status; mode: "sources" | "shortcuts" }) {
  const [draft, setDraft] = useState<ShortcutConfig | null>(null);
  const [formError, setFormError] = useState("");
  const [saving, setSaving] = useState(false);
  const [picking, setPicking] = useState(false);
  const [removeId, setRemoveId] = useState<string | null>(null);
  const editorRef = useRef<HTMLDialogElement>(null);
  const removeRef = useRef<HTMLDialogElement>(null);
  const editing = draft !== null;
  const removing = removeId !== null;
  useEffect(() => {
    if (editing) editorRef.current?.showModal();
  }, [editing]);
  useEffect(() => {
    if (removing) removeRef.current?.showModal();
  }, [removing]);
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
      {mode === "sources" && (
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
              刷新数据
            </button>
          </div>
          <p>在上方设备卡片中选择共享内容。会话只共享标题、项目名和状态。</p>
          <div className="source-grid">
            {(
              [
                ["codex.sessions", "近期会话"],
                ["codex.quota", "Codex 额度"],
                ["sub2api.usage", "API 用量"],
              ] as const
            ).map(([id, label]) => {
              const source = data.sources.find((s) => s.source_id === id);
              const fresh =
                source?.health === "ready" &&
                source.fresh_until > Date.now() / 1000;
              return (
                <section className="source-card" key={id}>
                  <h3>{label}</h3>
                  <p
                    className={`status-tag${fresh ? " success" : source?.health === "error" ? " danger" : " warning"}`}
                  >
                    {fresh
                      ? "已更新"
                      : source?.message ||
                        (id === "sub2api.usage" && !status.usage_config
                          ? "尚未连接来源"
                          : source?.observed_at
                            ? "上次数据，等待更新"
                            : "正在读取…")}
                  </p>
                  {id === "codex.sessions" ? (
                    <p>
                      近期 {data.sessions.length} 个 / 共 {data.session_total}{" "}
                      个会话
                    </p>
                  ) : id === "codex.quota" ? (
                    data.quotas.map((q) => (
                      <div className="quota-window" key={q.id}>
                        <strong>
                          {q.label} ·{" "}
                          {q.resets_at <= Date.now() / 1000
                            ? "等待刷新"
                            : `剩余 ${Math.round(q.remaining_percent)}%`}
                        </strong>
                        <div
                          className="quota-track"
                          role="progressbar"
                          aria-label={`${q.label}剩余额度`}
                          aria-valuenow={Math.round(q.remaining_percent)}
                          aria-valuemin={0}
                          aria-valuemax={100}
                        >
                          <span
                            style={{
                              width: `${Math.max(0, Math.min(100, q.remaining_percent))}%`,
                            }}
                          />
                        </div>
                        <small>
                          {new Date(q.resets_at * 1000).toLocaleString("zh-CN")}{" "}
                          重置
                        </small>
                      </div>
                    ))
                  ) : (
                    <UsageMetrics status={status} />
                  )}
                  {id === "codex.quota" && !data.quotas.length && (
                    <p>暂无可用额度，请确认 Codex 已登录后刷新。</p>
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
        </>
      )}
      {mode === "shortcuts" && (
        <>
          <div className="section-title">
            <h2>已添加入口</h2>
            <button
              disabled={busy || saving || picking}
              onClick={() => {
                setDraft({
                  id: crypto.randomUUID(),
                  name: "",
                  kind: "url",
                  target: "",
                  icon_png: "",
                });
                setFormError("");
              }}
            >
              添加入口
            </button>
          </div>
          {status.shortcuts.length === 0 && !draft && (
            <p className="source-card">
              还没有入口，添加一个常用网页或应用吧。
            </p>
          )}
          <ShortcutCatalog
            items={status.shortcuts}
            disabled={busy || saving || picking || editing || removing}
            onEdit={(item) => {
              setDraft({ ...item });
              setFormError("");
            }}
            onDelete={(id) => {
              setRemoveId(id);
              setFormError("");
            }}
            onReorder={(ids) =>
              void run(async () => {
                await call("reorder_shortcuts", { ids });
              })
            }
          />
          {removeId && (
            <dialog
              ref={removeRef}
              className="modal"
              aria-labelledby="remove-shortcut-title"
              onCancel={(event) => {
                if (saving) event.preventDefault();
                else setRemoveId(null);
              }}
            >
              <h2 id="remove-shortcut-title">删除入口？</h2>
              <p>
                「{status.shortcuts.find((item) => item.id === removeId)?.name}
                」将从工作台移除，电脑上的应用或网页不受影响。
              </p>
              {formError && (
                <p role="alert" className="notice error">
                  {formError}
                </p>
              )}
              <div className="modal-actions">
                <button disabled={saving} onClick={() => setRemoveId(null)}>
                  取消
                </button>
                <button
                  className="danger-button"
                  disabled={saving}
                  onClick={async () => {
                    setSaving(true);
                    setFormError("");
                    try {
                      await call("remove_shortcut", { id: removeId });
                      setRemoveId(null);
                      await run(async () => {});
                    } catch (error) {
                      setFormError(String(error));
                    } finally {
                      setSaving(false);
                    }
                  }}
                >
                  {saving ? "删除中…" : "删除"}
                </button>
              </div>
            </dialog>
          )}
          {draft && (
            <dialog
              ref={editorRef}
              className="modal shortcut-editor"
              aria-labelledby="shortcut-editor-title"
              onCancel={(event) => {
                if (saving || picking) event.preventDefault();
                else setDraft(null);
              }}
            >
              <form
                className="shortcut-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  void save();
                }}
              >
                <fieldset disabled={saving || picking}>
                  <h2 id="shortcut-editor-title">
                    {status.shortcuts.some((s) => s.id === draft.id)
                      ? "编辑入口"
                      : "新入口"}
                  </h2>
                  <label>
                    名称
                    <input
                      autoFocus
                      required
                      maxLength={64}
                      value={draft.name}
                      onChange={(e) =>
                        setDraft({ ...draft, name: e.target.value })
                      }
                    />
                  </label>
                  <label>
                    类型
                    <select
                      value={draft.kind}
                      onChange={(e) =>
                        setDraft({
                          ...draft,
                          kind: e.target.value,
                          target: "",
                          icon_png: "",
                        })
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
                      onChange={(e) =>
                        setDraft({
                          ...draft,
                          target: e.target.value,
                          icon_png: "",
                        })
                      }
                    />
                  </label>
                  {draft.kind === "app" && (
                    <button
                      type="button"
                      disabled={saving}
                      onClick={async () => {
                        setFormError("");
                        try {
                          setPicking(true);
                          const selected =
                            await call<ApplicationMetadata | null>(
                              "choose_application",
                            );
                          if (selected)
                            setDraft((current) =>
                              current && current.id === draft.id
                                ? {
                                    ...current,
                                    target: selected.target,
                                    name: current.name || selected.name,
                                    icon_png: selected.icon_png,
                                  }
                                : current,
                            );
                        } catch (e) {
                          setFormError(String(e));
                        } finally {
                          setPicking(false);
                        }
                      }}
                    >
                      选择应用
                    </button>
                  )}
                  {draft.kind === "app" && (
                    <p>选择电脑上的应用即可；路径只保存在这台电脑。</p>
                  )}
                  <div className="shortcut-icon-field">
                    <ShortcutIcon
                      key={draft.icon_png}
                      icon={draft.icon_png}
                      kind={draft.kind}
                    />
                    <div>
                      <strong>入口图标</strong>
                      <p>
                        {draft.icon_png
                          ? "已选择图标，保存后共享到设备。"
                          : "保存时自动读取应用或系统网页图标。"}
                      </p>
                      <div className="icon-actions">
                        <button
                          type="button"
                          onClick={async () => {
                            setFormError("");
                            setPicking(true);
                            try {
                              const icon = await call<string | null>(
                                "choose_shortcut_icon",
                              );
                              if (icon)
                                setDraft((current) =>
                                  current && current.id === draft.id
                                    ? { ...current, icon_png: icon }
                                    : current,
                                );
                            } catch (error) {
                              setFormError(
                                error instanceof Error
                                  ? error.message
                                  : String(error),
                              );
                            } finally {
                              setPicking(false);
                            }
                          }}
                        >
                          {picking ? "正在读取…" : "选择图片"}
                        </button>
                        {draft.icon_png && (
                          <button
                            type="button"
                            className="text-button"
                            onClick={() => setDraft({ ...draft, icon_png: "" })}
                          >
                            使用自动图标
                          </button>
                        )}
                      </div>
                    </div>
                  </div>
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
                </fieldset>
              </form>
            </dialog>
          )}
        </>
      )}
    </>
  );
}

function formatCost(value: number, currency: string) {
  const amount = value / 1_000_000;
  try {
    return new Intl.NumberFormat("zh-CN", {
      style: "currency",
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 6,
    }).format(amount);
  } catch {
    return `${amount.toLocaleString("zh-CN", { maximumFractionDigits: 6 })} ${currency}`;
  }
}

function UsageMetrics({ status }: { status: Status }) {
  const usages = status.workbench.api_usage;
  return usages.length ? (
    usages.map((usage) => (
      <div className="usage-metrics" key={usage.id}>
        <p className="usage-label">{usage.label}</p>
        <dl>
          <div>
            <dt>费用</dt>
            <dd>{formatCost(usage.actual_cost_micros, usage.currency)}</dd>
          </div>
          <div>
            <dt>Token</dt>
            <dd>{usage.token_count.toLocaleString("zh-CN")}</dd>
          </div>
          <div>
            <dt>TPM</dt>
            <dd>{usage.tpm.toLocaleString("zh-CN")}</dd>
          </div>
        </dl>
        <small>
          {new Date(usage.window_start * 1000).toLocaleString("zh-CN")} —{" "}
          {new Date(usage.window_end * 1000).toLocaleString("zh-CN")}
        </small>
      </div>
    ))
  ) : (
    <p>
      {status.usage_config
        ? "暂无可用用量，等待来源更新。"
        : "请在设置中连接 Sub2API 账号，再向设备共享。"}
    </p>
  );
}

export function UsageSettings({
  status,
  busy,
  run,
}: Actions & { status: Status }) {
  const [config, setConfig] = useState<UsageConfig>(
    () =>
      status.usage_config ?? {
        base_url: "",
        email: "",
        timezone: "Asia/Shanghai",
      },
  );
  const [password, setPassword] = useState("");
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState("");
  const [saved, setSaved] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [editing, setEditing] = useState(!status.usage_config);
  const source = status.workbench.sources.find(
    (item) => item.source_id === "sub2api.usage",
  );
  const fresh =
    source?.health === "ready" && source.fresh_until > Date.now() / 1000;
  const sameAccount = Boolean(
    status.usage_config &&
    status.usage_config.base_url === config.base_url.trim() &&
    status.usage_config.email === config.email.trim(),
  );
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    setFormError("");
    setSaved(false);
    const next = {
      base_url: config.base_url.trim().replace(/\/$/, ""),
      email: config.email.trim(),
      timezone: config.timezone.trim(),
    };
    try {
      const url = new URL(next.base_url);
      if (
        url.protocol !== "https:" ||
        url.username ||
        url.password ||
        url.search ||
        url.hash
      )
        throw new Error(
          "请填写 HTTPS 站点地址，不要包含账号、查询参数或片段。",
        );
      try {
        new Intl.DateTimeFormat("zh-CN", { timeZone: next.timezone });
      } catch {
        throw new Error("请填写有效时区，例如 Asia/Shanghai。");
      }
      if (!password && !sameAccount)
        throw new Error("连接新账号时请填写密码。");
      setSaving(true);
      await call("save_usage_source", { config: next, password });
      setConfig(next);
      setPassword("");
      setSaved(true);
      setEditing(false);
      await run(async () => {});
    } catch (error) {
      setFormError(error instanceof Error ? error.message : String(error));
    } finally {
      setSaving(false);
    }
  }
  return (
    <section className="settings-panel" aria-labelledby="usage-settings-title">
      <div className="panel-title">
        <h2 id="usage-settings-title">API 用量来源</h2>
        {status.usage_config && !editing && (
          <button
            className="text-button"
            disabled={busy || saving}
            onClick={() => {
              setConfig(status.usage_config!);
              setFormError("");
              setSaved(false);
              setEditing(true);
            }}
          >
            编辑连接
          </button>
        )}
      </div>
      <p>
        连接 Sub2API 账号，查看费用、Token 和 TPM。共享后，设备只显示用量数据。
      </p>
      {status.usage_config && (
        <div className="usage-account">
          <strong>{status.usage_config.email}</strong>
          <small>
            {status.usage_config.base_url} · {status.usage_config.timezone}
          </small>
          <p
            className={`status-tag${fresh ? " success" : source?.health === "error" ? " danger" : " warning"}`}
          >
            {fresh
              ? "已更新"
              : source?.message ||
                (source?.observed_at ? "上次数据，等待更新" : "等待更新")}
          </p>
          <UsageMetrics status={status} />
          {source?.observed_at ? (
            <small>
              上次更新{" "}
              {new Date(source.observed_at * 1000).toLocaleString("zh-CN")}
            </small>
          ) : null}
        </div>
      )}
      {saved && (
        <p className="save-success" role="status">
          连接设置已保存。
        </p>
      )}
      {editing && (
        <form className="usage-form" onSubmit={save}>
          <fieldset disabled={busy || saving}>
            <label>
              Sub2API 站点
              <input
                type="url"
                required
                maxLength={2048}
                placeholder="https://api.example.com"
                value={config.base_url}
                onChange={(event) =>
                  setConfig({ ...config, base_url: event.target.value })
                }
                autoComplete="url"
              />
            </label>
            <label>
              邮箱
              <input
                type="email"
                required
                maxLength={254}
                value={config.email}
                onChange={(event) =>
                  setConfig({ ...config, email: event.target.value })
                }
                autoComplete="username"
              />
            </label>
            <label>
              密码
              <input
                type="password"
                required={!sameAccount}
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                placeholder={
                  sameAccount ? "留空保留已保存的密码" : "输入账号密码"
                }
              />
            </label>
            <label>
              统计时区
              <input
                required
                maxLength={64}
                value={config.timezone}
                onChange={(event) =>
                  setConfig({ ...config, timezone: event.target.value })
                }
                placeholder="Asia/Shanghai"
                autoComplete="off"
              />
            </label>
            <p className="field-help">
              时区需与站点的统计时区一致，例如
              Asia/Shanghai。更换站点或邮箱时需重新输入密码。账号凭据只保存在这台电脑，不共享到设备。
            </p>
            <div className="modal-actions">
              <button className="primary">
                {saving ? "保存中…" : "保存连接"}
              </button>
              {status.usage_config && (
                <button
                  type="button"
                  onClick={() => {
                    setEditing(false);
                    setPassword("");
                    setFormError("");
                  }}
                >
                  取消
                </button>
              )}
            </div>
          </fieldset>
        </form>
      )}
      {formError && (
        <p className="notice error" role="alert">
          {formError}
        </p>
      )}
      {status.usage_config && !editing && (
        <div className="usage-actions">
          <button
            disabled={busy || saving}
            onClick={() =>
              void run(async () => {
                await call("refresh_sources");
              })
            }
          >
            刷新用量
          </button>
          {removing ? (
            <div className="remove-confirm">
              <p>移除来源后，设备将无法继续获取该账号的用量。</p>
              <button
                className="destructive"
                disabled={busy || saving}
                onClick={async () => {
                  setSaving(true);
                  setFormError("");
                  try {
                    await call("remove_usage_source");
                    setConfig({
                      base_url: "",
                      email: "",
                      timezone: "Asia/Shanghai",
                    });
                    setPassword("");
                    setSaved(false);
                    setRemoving(false);
                    setEditing(true);
                    await run(async () => {});
                  } catch (error) {
                    setFormError(
                      error instanceof Error ? error.message : String(error),
                    );
                  } finally {
                    setSaving(false);
                  }
                }}
              >
                确认移除
              </button>
              <button disabled={saving} onClick={() => setRemoving(false)}>
                取消
              </button>
            </div>
          ) : (
            <button
              className="text-button"
              disabled={busy || saving}
              onClick={() => setRemoving(true)}
            >
              移除来源
            </button>
          )}
        </div>
      )}
    </section>
  );
}
