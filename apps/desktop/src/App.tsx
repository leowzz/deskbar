import { useEffect, useRef, useState } from "react";
import {
  Monitor,
  Plus,
  Smartphone,
  ArrowUpRight,
  Copy,
  Check,
  X,
  RefreshCw,
  Wifi,
  AlertCircle,
} from "lucide-react";
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
        <a className="brand" href="#">
          <span className="brand-mark">
            <Monitor size={21} />
          </span>
          Desklet
        </a>
        <div className="nav-label">这台电脑</div>
        <div className="nav-item">
          <Smartphone size={18} />
          我的设备<span>{status?.devices.length ?? "—"}</span>
        </div>
        <div className="sidebar-bottom">
          <span className="status-dot" />
          局域网直连<p>让身旁的屏幕，成为工作台。</p>
        </div>
      </aside>
      <main>
        <header>
          <div>
            <p className="eyebrow">我的设备</p>
            <h1>把工作台放在身旁</h1>
            <p className="subtitle">
              连接 Android 设备，在另一块屏幕上查看这台电脑。
            </p>
          </div>
          <button
            className="primary"
            disabled={!status || busy}
            onClick={invite}
          >
            <Plus size={18} />
            连接设备
          </button>
        </header>

        {(error || loadError) && (
          <div className="notice error" role="alert">
            <AlertCircle size={19} />
            <span>{error || loadError}</span>
            <button aria-label="重试" onClick={() => void run(async () => {})}>
              <RefreshCw size={17} />
            </button>
          </div>
        )}

        <section className="computer-card">
          <span className="computer-icon">
            <Monitor size={30} strokeWidth={1.5} />
          </span>
          <div className="computer-info">
            <h2>{status?.name ?? "这台电脑"}</h2>
            <p>
              {status
                ? "Desklet 正在运行"
                : loadError
                  ? "连接暂不可用"
                  : "正在读取连接状态"}
            </p>
          </div>
          <span className="connection-status">
            <span className={status ? "status-dot" : "status-dot muted"} />
            {status ? "可连接" : "未连接"}
          </span>
        </section>
        {status?.discovery_warning && (
          <div className="notice">
            <Wifi size={18} />
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
                <Smartphone size={26} strokeWidth={1.5} />
                <div>
                  <h3>{device.name}</h3>
                  <p>
                    {new Date(device.paired_at * 1000).toLocaleDateString(
                      "zh-CN",
                    )}{" "}
                    配对
                  </p>
                </div>
                {removeId === device.id ? (
                  <div className="remove-confirm">
                    <span>移除后需要重新配对</span>
                    <button
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
                    <button onClick={() => setRemoveId(null)}>取消</button>
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
            <div className="device-illustration">
              <Monitor size={70} strokeWidth={1} />
              <Smartphone size={42} strokeWidth={1.2} />
            </div>
            <h2>为电脑添一块屏幕</h2>
            <p>
              在 Android 上打开 Desklet，
              <br />
              扫描连接邀请，再回到这里确认。
            </p>
            <button
              className="secondary"
              disabled={!status || busy}
              onClick={invite}
            >
              连接第一台设备
              <ArrowUpRight size={17} />
            </button>
          </section>
        )}

        <footer>
          <Wifi size={16} />
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
              访问本地网络。访客网络可能禁止设备互相连接。
            </p>
            <p>自动发现不可用时，可以扫描或粘贴完整连接邀请。</p>
            {status?.addresses.map((address) => (
              <code key={address}>{address}</code>
            ))}
          </section>
        )}
      </main>

      {(invitation || pending) && (
        <dialog
          ref={dialogRef}
          onCancel={(event) => {
            event.preventDefault();
            if (!busy) close();
          }}
          className="modal"
          aria-labelledby="pair-title"
        >
          <button
            className="close-button"
            aria-label="关闭连接邀请"
            disabled={busy}
            onClick={close}
          >
            <X size={20} />
          </button>
          {pending ? (
            <>
              <div className="modal-symbol">
                <Smartphone size={32} />
              </div>
              <h2 id="pair-title">允许连接这台设备？</h2>
              <p className="request-name">{pending.name}</p>
              <p>
                只确认你正在操作的设备。连接后，它可以读取这台电脑共享的状态；你随时可以移除它。
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
              <p className="eyebrow">添加一块屏幕</p>
              <h2 id="pair-title">在 Android 上扫码连接</h2>
              <p>打开 Desklet，点击「扫码连接电脑」。</p>
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
                        <RefreshCw size={16} />
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
                {copied ? <Check size={17} /> : <Copy size={17} />}
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
