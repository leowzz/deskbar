import { useEffect, useRef, useState } from "react";
import { call, type Status } from "./api";

export function WorkbenchEditor({ status }: { status: Status }) {
  const [deviceId, setDeviceId] = useState(status.devices[0]?.id ?? "");
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const frame = useRef<HTMLIFrameElement>(null);
  const selected = status.devices.find((d) => d.id === deviceId);
  const selectedRef = useRef(selected);
  selectedRef.current = selected;

  useEffect(() => {
    if (!selected && !editing) setDeviceId(status.devices[0]?.id ?? "");
  }, [selected, status.devices, editing]);

  useEffect(() => {
    if (!deviceId) return;
    let active = true;
    let ready = false;
    let fetching = false;
    let saving = false;
    setLoading(true);
    setError("");
    function send(message: unknown) {
      frame.current?.contentWindow?.postMessage(
        { channel: "deskbar-editor", message: JSON.stringify(message) },
        window.location.origin,
      );
    }
    async function refresh() {
      if (!ready || fetching || !active) return;
      fetching = true;
      try {
        const snapshot = await call("device_workbench", { id: deviceId });
        if (active) {
          send({
            type: "state",
            snapshot,
            display: selectedRef.current?.display ?? null,
          });
          setLoading(false);
          setError("");
        }
      } catch (e) {
        if (active) setError(String(e));
      } finally {
        fetching = false;
      }
    }
    async function receive(event: MessageEvent) {
      if (
        event.source !== frame.current?.contentWindow ||
        event.origin !== window.location.origin ||
        event.data?.channel !== "deskbar-editor"
      )
        return;
      let message;
      try {
        message = JSON.parse(event.data.message);
      } catch {
        return;
      }
      if (message.type === "ready") {
        ready = true;
        void refresh();
      } else if (message.type === "editing") {
        setEditing(message.value === true);
      } else if (message.type === "save" && !saving) {
        saving = true;
        try {
          const revision = await call<number>("save_layout", {
            id: deviceId,
            expectedRevision: message.expectedRevision,
            layout: message.layout,
          });
          if (active)
            send({ type: "saved", requestId: message.requestId, revision });
        } catch (e) {
          if (active)
            send({
              type: "saved",
              requestId: message.requestId,
              error: String(e),
            });
        } finally {
          saving = false;
        }
      }
    }
    window.addEventListener("message", receive);
    const timer = window.setInterval(refresh, 1000);
    const timeout = window.setTimeout(() => {
      if (!ready) setError("编辑器未能加载，请重新打开连接助手。");
    }, 30000);
    return () => {
      active = false;
      window.removeEventListener("message", receive);
      window.clearInterval(timer);
      window.clearTimeout(timeout);
    };
  }, [deviceId]);

  if (!status.devices.length) return <p>连接设备后即可编辑工作台。</p>;
  const online =
    selected?.display && Date.now() / 1000 - selected.display.seen_at < 15;
  return (
    <section className="workbench-editor">
      <div className="editor-device-row">
        <label>
          设备
          <select
            aria-label="编辑的设备"
            value={deviceId}
            disabled={editing}
            onChange={(e) => setDeviceId(e.target.value)}
          >
            {status.devices.map((device) => (
              <option value={device.id} key={device.id}>
                {device.name}
              </option>
            ))}
          </select>
        </label>
        <span className={`status-tag ${online ? "success" : "warning"}`}>
          {!online
            ? "设备离线 · 可编辑已保存布局"
            : selected.display?.layout_revision === selected.layout_revision
              ? "设备已同步"
              : "等待设备接收布局"}
        </span>
        {editing && <span>草稿预览 · 完成后同步到设备</span>}
      </div>
      {error && (
        <p className="notice error" role="alert">
          {error}
        </p>
      )}
      {loading && !error && <p role="status">正在加载工作台编辑器…</p>}
      <iframe
        key={deviceId}
        ref={frame}
        title="工作台实时预览与编辑"
        src="/editor/index.html"
      />
    </section>
  );
}
