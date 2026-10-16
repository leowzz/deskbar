import { useEffect, useRef, useState } from "react";
import { WorkbenchSettings, Sharing } from "./WorkbenchSettings";
import QRCode from "qrcode";
import { call, type Invitation, type Status } from "./api";

function message(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

export function App() {
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
        <a className="brand" href="#" aria-label="Desklet 连接助手">
          Desklet<span className="brand-role">连接助手</span>
        </a>
        <div className="nav-label">这台电脑</div>
        <div className="nav-item">
          我的设备<span>{status?.devices.length ?? "—"}</span>
        </div>
        <div className="sidebar-bottom">
          局域网直连<p>让身旁的屏幕，成为工作台。</p>
        </div>
      </aside>
      <main>
        <header>
          <div>
            <p className="eyebrow">我的设备</p>
            <h1>
              把工作台
              <br />
              放在身旁
            </h1>
            <p className="subtitle">
              连接 Android 设备，在另一块屏幕上查看这台电脑。
            </p>
          </div>
          <button
            className="primary"
            disabled={!status || busy}
            onClick={invite}
          >
            连接设备
          </button>
        </header>
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
                  <h3>{device.name}</h3>
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
              在 Android 上打开 Desklet 工作台，扫描连接邀请，再回到这里确认。
            </p>
            <button className="secondary" disabled={busy} onClick={invite}>
              连接第一台设备
            </button>
          </section>
        )}
        {status && <WorkbenchSettings status={status} busy={busy} run={run} />}
        <footer>
          <span>电脑和设备需要连接同一局域网。</span>
          <button
            className="text-button"
            onClick={() => setShowAddresses(!showAddresses)}
          >
            {showAddresses ? "收起" : "连接帮助"}
          </button>
        </footer>
        {showAddresses && (
          <section className="help">
            <h3>找不到电脑？</h3>
            <p>
              确认两端已连接同一 Wi-Fi，并允许 Desklet
              连接助手访问本地网络。访客网络可能禁止设备互相连接。
            </p>
            <p>自动发现不可用时，可以扫描或粘贴完整连接邀请。</p>
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
            <span>连接设备</span>
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
              <h2 id="pair-title">
                允许连接
                <br />
                这台设备？
              </h2>
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
              <h2 id="pair-title">
                在 Android 上<br />
                扫码连接
              </h2>
              <p>打开 Desklet 工作台，点击「扫码连接电脑」。</p>
              <div className="qr">
                {remaining > 0 && qr ? (
                  <img src={qr} alt="Desklet 一次性连接邀请二维码" />
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
              <p>复制完整邀请，在 Android 的「粘贴邀请」中输入。</p>
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
