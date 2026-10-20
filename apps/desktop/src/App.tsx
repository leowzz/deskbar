import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { WorkbenchSettings, Sharing, UsageSettings } from "./WorkbenchSettings";
import { WorkbenchEditor } from "./WorkbenchEditor";
import QRCode from "qrcode";
import { isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { call, type Invitation, type Status } from "./api";

function message(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

import { UpdateSettings } from "./UpdateSettings";

type View = "devices" | "workbench" | "shortcuts" | "settings";
type Theme = "light" | "dark";
const themeKey = "deskbar.theme";

function initialTheme(): Theme {
  try {
    return localStorage.getItem(themeKey) === "dark" ? "dark" : "light";
  } catch {
    return "light";
  }
}

function Icon({
  name,
}: {
  name: "desk" | "devices" | "grid" | "settings" | "tablet";
}) {
  const paths = {
    desk: (
      <path
        d="M24 18H46C65 18 78 31 78 48S65 78 46 78H24V66H46C58 66 66 59 66 48S58 30 46 30H36V54H24Z"
        transform="scale(.25)"
        fill="currentColor"
        stroke="none"
      />
    ),
    devices: (
      <>
        <path d="M12 16H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v2M8 16v4m-3 0h6" />
        <rect x="15" y="10" width="7" height="11" rx="1.5" />
      </>
    ),
    grid: (
      <>
        <rect x="3" y="3" width="7" height="7" rx="1.5" />
        <rect x="14" y="3" width="7" height="7" rx="1.5" />
        <rect x="3" y="14" width="7" height="7" rx="1.5" />
        <rect x="14" y="14" width="7" height="7" rx="1.5" />
      </>
    ),
    settings: (
      <>
        <path d="M4 7h2m6 0h8M4 17h8m6 0h2" />
        <circle cx="9" cy="7" r="3" />
        <circle cx="15" cy="17" r="3" />
      </>
    ),
    tablet: (
      <>
        <rect x="5" y="2" width="14" height="20" rx="2" />
        <path d="M11 18h2" />
      </>
    ),
  };
  return (
    <svg
      className="icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.65"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  );
}

export function App() {
  const [openedEditor, setOpenedEditor] = useState(false);
  const [view, setView] = useState<View>("devices");
  const [theme, setTheme] = useState<Theme>(initialTheme);
  const [themeError, setThemeError] = useState("");
  useLayoutEffect(() => {
    document.documentElement.dataset.theme = theme;
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", theme === "dark" ? "#191A1C" : "#F6F7F9");
  }, [theme]);
  useEffect(() => {
    if (!isTauri()) return;
    let active = true;
    async function syncWindowTheme() {
      try {
        const nativeWindow = getCurrentWindow();
        await Promise.all([
          nativeWindow.setTheme(theme),
          nativeWindow.setBackgroundColor(
            theme === "dark" ? "#191A1C" : "#F6F7F9",
          ),
        ]);
      } catch {
        if (active)
          setThemeError(
            "主题已应用，但窗口外观未能同步。可退出并重新打开连接助手后重试。",
          );
      }
    }
    void syncWindowTheme();
    return () => {
      active = false;
    };
  }, [theme]);
  function chooseTheme(value: Theme) {
    setTheme(value);
    try {
      localStorage.setItem(themeKey, value);
      setThemeError("");
    } catch {
      setThemeError("主题已应用，但未能保存。下次启动可能恢复浅色。");
    }
  }
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState("");
  const [loadError, setLoadError] = useState("");
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [invitation, setInvitation] = useState<Invitation | null>(null);
  const [qr, setQr] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [clock, setClock] = useState(Date.now());
  const [removeId, setRemoveId] = useState<string | null>(null);
  const [showAddresses, setShowAddresses] = useState(false);

  useEffect(() => {
    let mounted = true;
    async function refresh() {
      try {
        const next = await call<Status>("agent_status");
        if (mounted) {
          setStatus(next);
          setLoadError("");
        }
      } catch (e) {
        if (mounted) setLoadError(message(e));
      }
    }
    void refresh();
    const timer = window.setInterval(() => {
      setClock(Date.now());
      void refresh();
    }, 2000);
    return () => {
      mounted = false;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    let current = true;
    setQr("");
    if (invitation)
      void QRCode.toDataURL(invitation.uri, {
        width: 280,
        margin: 2,
        errorCorrectionLevel: "M",
      })
        .then((value) => {
          if (current) setQr(value);
        })
        .catch((e) => setError(message(e)));
    return () => {
      current = false;
    };
  }, [invitation]);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError("");
    try {
      await action();
      setStatus(await call<Status>("agent_status"));
    } catch (e) {
      setError(message(e));
    } finally {
      setBusy(false);
    }
  }

  function invite() {
    void run(async () => {
      setCopied(false);
      setInvitation(await call<Invitation>("create_invitation"));
      setClock(Date.now());
    });
  }
  function close() {
    void run(async () => {
      await call("cancel_pairing");
      setInvitation(null);
    });
  }
  const remaining = invitation
    ? Math.max(0, Math.ceil(invitation.expires_at - clock / 1000))
    : 0;
  const pending = status?.pending;
  const pairingOpen = Boolean(invitation || pending);
  useEffect(() => {
    if (pairingOpen && !dialogRef.current?.open) dialogRef.current?.showModal();
  }, [pairingOpen]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <Icon name="desk" />
          <span>DeskBar</span>
        </div>
        <nav aria-label="主导航">
          {(
            [
              ["devices", "我的设备", "devices"],
              ["workbench", "屏幕编辑", "tablet"],
              ["shortcuts", "快捷入口", "grid"],
              ["settings", "设置", "settings"],
            ] as const
          ).map(([id, label, icon]) => (
            <button
              key={id}
              className={`nav-item${view === id ? " active" : ""}`}
              aria-current={view === id ? "page" : undefined}
              onClick={() => {
                setView(id);
                if (id === "workbench") setOpenedEditor(true);
              }}
            >
              <Icon name={icon} />
              <span>{label}</span>
              {id === "devices" && (
                <span className="nav-count">
                  {status?.devices.length ?? "—"}
                </span>
              )}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <strong>{status?.name ?? "这台电脑"}</strong>
        </div>
      </aside>
      <main className={view === "workbench" ? "editor-main" : undefined}>
        {view !== "workbench" && (
          <header>
            <div>
              <h1>
                {view === "devices"
                  ? "我的设备"
                  : view === "shortcuts"
                    ? "快捷入口"
                    : "设置"}
              </h1>
              {(view === "devices" || view === "shortcuts") && (
                <p className="subtitle">
                  {view === "devices"
                    ? "连接 Android 设备，将身旁的屏幕变成工作台。"
                    : "管理设备可以在这台电脑上打开的网页和应用。"}
                </p>
              )}
            </div>
            {view === "devices" && (
              <button
                className="primary"
                disabled={!status || busy}
                onClick={invite}
              >
                显示备用二维码
              </button>
            )}
          </header>
        )}
        {(error || loadError) && (
          <div className="notice error" role="alert">
            <strong>连接提示</strong>
            <span>{error || loadError}</span>
            <button
              className="text-button"
              onClick={() => void run(async () => {})}
            >
              重试
            </button>
          </div>
        )}
        {openedEditor && status && (
          <div hidden={view !== "workbench"}>
            <WorkbenchEditor status={status} />
          </div>
        )}
        {view === "devices" && (
          <>
            <section className="computer-card">
              <div className="computer-info">
                <p className="eyebrow">这台电脑</p>
                <h2>{status?.name ?? "这台电脑"}</h2>
                <p>
                  {status
                    ? "连接助手正在运行"
                    : loadError
                      ? "连接暂不可用"
                      : "正在读取连接状态"}
                </p>
              </div>
              <span className={`status-tag${status ? " success" : ""}`}>
                {status ? "可连接" : "未连接"}
              </span>
            </section>
            {status?.discovery_warning && (
              <div className="notice">
                <strong>自动发现</strong>
                <span>{status.discovery_warning}</span>
              </div>
            )}
            <div className="section-title">
              <h2>已配对设备</h2>
              <span>{status?.devices.length ?? "—"} 台</span>
            </div>
            {!status ? (
              <section className="empty-state">
                <h2>{loadError ? "连接尚未就绪" : "正在读取设备"}</h2>
                <p>
                  {loadError
                    ? "请处理上方提示后重试。"
                    : "稍等片刻，即可管理你的设备。"}
                </p>
              </section>
            ) : status.devices.length ? (
              <div className="device-list">
                {status.devices.map((device) => (
                  <article className="device-card" key={device.id}>
                    <div className="device-info">
                      <div className="device-heading">
                        <span className="device-icon">
                          <Icon name="tablet" />
                        </span>
                        <div>
                          <h3>{device.name}</h3>
                          <span className="device-state">已配对</span>
                        </div>
                      </div>
                      <p>
                        {new Date(device.paired_at * 1000).toLocaleDateString(
                          "zh-CN",
                        )}{" "}
                        配对
                      </p>
                      <Sharing device={device} busy={busy} run={run} />
                    </div>
                    {removeId === device.id ? (
                      <div className="remove-confirm">
                        <p>移除后需要重新配对</p>
                        <button
                          className="destructive"
                          disabled={busy}
                          onClick={() =>
                            void run(async () => {
                              await call("revoke_device", { id: device.id });
                              setRemoveId(null);
                            })
                          }
                        >
                          确认移除
                        </button>
                        <button
                          className="secondary"
                          onClick={() => setRemoveId(null)}
                        >
                          取消
                        </button>
                      </div>
                    ) : (
                      <button
                        className="text-button"
                        onClick={() => setRemoveId(device.id)}
                      >
                        移除
                      </button>
                    )}
                  </article>
                ))}
              </div>
            ) : (
              <section className="empty-state">
                <h2>为电脑添一块屏幕</h2>
                <p>
                  打开 Android 上的 DeskBar
                  工作台，点击附近的电脑名称；连接请求会出现在这里，确认一次即可。
                </p>
                <button className="secondary" disabled={busy} onClick={invite}>
                  找不到电脑？显示备用二维码
                </button>
              </section>
            )}
          </>
        )}
        {status && (view === "devices" || view === "shortcuts") && (
          <WorkbenchSettings
            status={status}
            busy={busy}
            run={run}
            mode={view === "shortcuts" ? "shortcuts" : "sources"}
          />
        )}
        {!status && view === "shortcuts" && (
          <section className="empty-state">
            <h2>{loadError ? "未能读取快捷入口" : "正在读取快捷入口"}</h2>
            <p>
              {loadError
                ? "请处理上方提示后重试。"
                : "稍等片刻，即可管理常用网页和应用。"}
            </p>
          </section>
        )}
        {view === "settings" && (
          <section
            className="settings-panel"
            aria-labelledby="appearance-title"
          >
            <h2 id="appearance-title">外观</h2>
            <div className="theme-options" role="group" aria-label="应用主题">
              {(
                [
                  ["light", "铂银", "浅色"],
                  ["dark", "墨黑", "暗色"],
                ] as const
              ).map(([value, label, description]) => (
                <button
                  key={value}
                  className={`theme-option ${value}`}
                  aria-pressed={theme === value}
                  onClick={() => chooseTheme(value)}
                >
                  <span className="theme-preview" aria-hidden="true">
                    <i />
                    <i />
                    <i />
                  </span>
                  <span>
                    <strong>{label}</strong>
                    <small>
                      {description}
                      {value === "light" ? " · 默认" : ""}
                    </small>
                  </span>
                  <span className="theme-selected" aria-hidden="true">
                    {theme === value ? "✓" : ""}
                  </span>
                </button>
              ))}
            </div>
            {themeError && (
              <p className="notice error" role="alert">
                {themeError}
              </p>
            )}
          </section>
        )}
        {view === "settings" && status && (
          <UsageSettings status={status} busy={busy} run={run} />
        )}
        {view === "settings" && <UpdateSettings />}
        {view !== "workbench" && (
          <footer>
            <span>电脑和设备需要连接同一局域网。</span>
            <button
              className="text-button"
              onClick={() => setShowAddresses(!showAddresses)}
            >
              {showAddresses ? "收起" : "连接帮助"}
            </button>
          </footer>
        )}
        {showAddresses && view !== "workbench" && (
          <section className="help">
            <h3>找不到电脑？</h3>
            <p>
              确认两端已连接同一 Wi-Fi，并允许 DeskBar
              连接助手访问本地网络。访客网络可能禁止设备互相连接。
            </p>
            <p>
              两端会自动查找同一局域网内的电脑；找不到时，可以扫描或粘贴备用邀请。
            </p>
            {status?.addresses.map((address) => (
              <code key={address}>{address}</code>
            ))}
          </section>
        )}
      </main>
      {pairingOpen && (
        <dialog
          ref={dialogRef}
          onCancel={(event) => {
            event.preventDefault();
            if (!busy) close();
          }}
          className="modal"
          aria-labelledby="pair-title"
        >
          <div className="modal-toolbar">
            <span>备用连接</span>
            <button
              className="text-button"
              aria-label="关闭连接邀请"
              disabled={busy}
              onClick={close}
            >
              关闭
            </button>
          </div>
          {pending ? (
            <>
              <h2 id="pair-title">允许连接这台设备？</h2>
              <p className="request-name">{pending.name}</p>
              <p>
                只确认你正在操作的设备。连接后，请在设备卡片中选择共享内容；你随时可以修改权限或移除设备。
              </p>
              <div className="modal-actions">
                <button className="secondary" disabled={busy} onClick={close}>
                  拒绝
                </button>
                <button
                  className="primary"
                  disabled={busy}
                  onClick={() =>
                    void run(async () => {
                      await call("approve_device", { id: pending.id });
                      setInvitation(null);
                    })
                  }
                >
                  允许连接
                </button>
              </div>
            </>
          ) : (
            <>
              <h2 id="pair-title">备用连接方式</h2>
              <p>
                默认方式是 Android
                自动发现这台电脑；找不到时再扫描下面的二维码。
              </p>
              <div className="qr">
                {remaining > 0 && qr ? (
                  <img src={qr} alt="DeskBar 一次性连接邀请二维码" />
                ) : (
                  <div>
                    <p>{remaining ? "正在生成邀请…" : "邀请已过期"}</p>
                    {!remaining && (
                      <button
                        className="secondary"
                        disabled={busy}
                        onClick={invite}
                      >
                        重新生成
                      </button>
                    )}
                  </div>
                )}
              </div>
              <p className="expires">
                {remaining
                  ? `邀请在 ${remaining} 秒后失效，连接还需你确认`
                  : "重新生成后，请再次扫码"}
              </p>
              <div className="divider" />
              <h3>设备没有摄像头？</h3>
              <p>复制备用邀请，在 Android 的「粘贴邀请」中输入。</p>
              <button
                className="secondary full"
                disabled={!remaining}
                onClick={() =>
                  void navigator.clipboard
                    .writeText(invitation!.uri)
                    .then(() => setCopied(true))
                    .catch(() => setError("未能复制，请重试"))
                }
              >
                {copied ? "已复制邀请" : "复制连接邀请"}
              </button>
            </>
          )}
          {error && (
            <p role="alert" className="modal-error">
              {error}
            </p>
          )}
        </dialog>
      )}
    </div>
  );
}
