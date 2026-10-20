import { useEffect, useRef, useState } from "react";
import { call, type Device, type DeviceDisplay, type Status } from "./api";

type CachedDeviceSize = Pick<DeviceDisplay, "width" | "height">;

function deviceSizeKey(id: string) {
  return `deskbar.device-size.${id}`;
}

function readDeviceSize(id: string): CachedDeviceSize | null {
  try {
    const value = JSON.parse(localStorage.getItem(deviceSizeKey(id)) ?? "null");
    if (
      !value ||
      !Number.isFinite(value.width) ||
      !Number.isFinite(value.height) ||
      value.width <= 0 ||
      value.height <= 0
    )
      return null;
    return { width: value.width, height: value.height };
  } catch {
    return null;
  }
}

export function WorkbenchEditor({
  status,
  active = true,
}: {
  status: Status;
  active?: boolean;
}) {
  const [deviceId, setDeviceId] = useState(status.devices[0]?.id ?? "");
  const selected =
    status.devices.find((device) => device.id === deviceId) ??
    status.devices[0];

  useEffect(() => {
    setDeviceId(selected?.id ?? "");
  }, [selected?.id]);

  if (!selected) return <p>连接设备后即可编辑工作台。</p>;
  return (
    <DeviceWorkbenchEditor
      key={selected.id}
      status={status}
      selected={selected}
      active={active}
      onSelectDevice={setDeviceId}
    />
  );
}

// A removed device ends its entire editing session, including its iframe,
// pending requests, cached dimensions and editing lock. A new pairing has a new
// ID even when the device name stays the same.
function DeviceWorkbenchEditor({
  status,
  selected,
  active,
  onSelectDevice,
}: {
  status: Status;
  selected: Device;
  active: boolean;
  onSelectDevice: (id: string) => void;
}) {
  const deviceId = selected.id;
  const [editing, setEditing] = useState(false);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const frame = useRef<HTMLIFrameElement>(null);
  const [cachedSize, setCachedSize] = useState<CachedDeviceSize | null>(() =>
    readDeviceSize(deviceId),
  );
  const displayRef = useRef<DeviceDisplay | null>(null);
  const activeRef = useRef(active);
  const refreshRef = useRef<(() => void) | null>(null);
  activeRef.current = active;
  useEffect(() => {
    if (active) refreshRef.current?.();
  }, [active]);

  useEffect(() => {
    const display = selected?.display;
    if (
      !display ||
      !Number.isFinite(display.width) ||
      !Number.isFinite(display.height)
    )
      return;
    const size = { width: display.width, height: display.height };
    try {
      localStorage.setItem(deviceSizeKey(deviceId), JSON.stringify(size));
    } catch {
      // A private browser storage failure should not block editing.
    }
    setCachedSize((previous) =>
      previous?.width === size.width && previous.height === size.height
        ? previous
        : size,
    );
  }, [deviceId, selected?.display]);

  const display =
    selected?.display ??
    (cachedSize
      ? {
          width: cachedSize.width,
          height: cachedSize.height,
          text_scale: 1,
          dark: false,
          page_id: "",
          layout_revision: selected?.layout_revision ?? 0,
          seen_at: 0,
        }
      : null);
  displayRef.current = display;

  useEffect(() => {
    if (!deviceId) return;
    let active = true;
    let ready = false;
    let fetching = false;
    let saving = false;
    let lastState = "";
    setLoading(true);
    setError("");
    function send(message: unknown) {
      frame.current?.contentWindow?.postMessage(
        { channel: "deskbar-editor", message: JSON.stringify(message) },
        window.location.origin,
      );
    }
    async function refresh() {
      if (
        !ready ||
        fetching ||
        !active ||
        !activeRef.current ||
        document.hidden
      )
        return;
      fetching = true;
      try {
        const snapshot = await call<Record<string, unknown>>(
          "device_workbench",
          {
            id: deviceId,
          },
        );
        if (active && activeRef.current && !document.hidden) {
          const display = displayRef.current;
          // Heartbeats and server time change every poll without changing the
          // preview. Avoid decoding and rebuilding the entire Dart document.
          const state = JSON.stringify({
            snapshot: { ...snapshot, server_time: undefined },
            display: display && {
              ...display,
              seen_at: undefined,
              online: Date.now() / 1000 - display.seen_at < 15,
            },
          });
          if (state !== lastState) {
            send({
              type: "state",
              snapshot,
              display,
            });
            lastState = state;
          }
          setLoading(false);
          setError("");
        }
      } catch (e) {
        if (active) setError(String(e));
      } finally {
        fetching = false;
      }
    }
    refreshRef.current = refresh;
    const resume = () => void refresh();
    document.addEventListener("visibilitychange", resume);
    async function receive(event: MessageEvent) {
      if (
        !active ||
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
        lastState = "";
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
      refreshRef.current = null;
      document.removeEventListener("visibilitychange", resume);
      window.removeEventListener("message", receive);
      window.clearInterval(timer);
      window.clearTimeout(timeout);
    };
  }, [deviceId]);

  return (
    <section className="workbench-editor">
      <div
        className="editor-device-switcher"
        role="group"
        aria-label="编辑的设备"
      >
        {status.devices.map((device) => {
          const summary = device.id.slice(0, 8);
          const connected =
            device.display && Date.now() / 1000 - device.display.seen_at < 15;
          const updated =
            connected &&
            device.display?.layout_revision === device.layout_revision;
          const deviceStatus = !connected
            ? "离线"
            : updated
              ? "设备已更新"
              : "等待设备应用布局";
          return (
            <button
              type="button"
              key={device.id}
              className="editor-device-button"
              data-device-id={device.id}
              aria-label={`${device.name} · ${summary}`}
              aria-pressed={device.id === deviceId}
              title={`设备标识：${device.id}`}
              disabled={editing}
              onClick={() => onSelectDevice(device.id)}
            >
              <span className="editor-device-name">{device.name}</span>
              {editing && device.id === deviceId && (
                <span className="editor-device-editing">
                  编辑中 · 更改会自动应用
                </span>
              )}
              <span className="editor-device-summary">
                <code>#{summary}</code>
              </span>
              <span
                className={`editor-device-status status-tag ${updated ? "success" : "warning"}`}
                title={
                  connected
                    ? `已连接 · ${deviceStatus}`
                    : "设备离线 · 可编辑当前布局"
                }
              >
                {deviceStatus}
              </span>
            </button>
          );
        })}
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
