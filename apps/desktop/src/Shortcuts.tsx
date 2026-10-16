import { useEffect, useRef, useState } from "react";
import { isTauri } from "@tauri-apps/api/core";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { call, type ApplicationMetadata, type ShortcutConfig } from "./api";
import { ShortcutCatalog, ShortcutIcon } from "./ShortcutCatalog";
import {
  applyWebsiteInfo,
  canFetchWebsiteInfo,
  duplicateShortcut,
  type WebsiteInfo,
} from "./shortcut-model";

type Recommendations = {
  supported: boolean;
  items: { app: ApplicationMetadata; lastUsed: number }[];
};
const message = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

export function ShortcutGlyph({
  name,
}: {
  name: "plus" | "globe" | "refresh" | "close" | "image";
}) {
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
      {name === "plus" ? (
        <path d="M12 5v14M5 12h14" />
      ) : name === "globe" ? (
        <>
          <circle cx="12" cy="12" r="9" />
          <ellipse cx="12" cy="12" rx="4" ry="9" />
          <path d="M3 12h18" />
        </>
      ) : name === "refresh" ? (
        <>
          <path d="M20 7v5h-5M4 17v-5h5" />
          <path d="M6 7a7 7 0 0 1 12-1l2 6M4 12l2 6a7 7 0 0 0 12-1" />
        </>
      ) : name === "close" ? (
        <path d="m6 6 12 12M6 18 18 6" />
      ) : (
        <>
          <rect x="3" y="3" width="18" height="18" rx="3" />
          <circle cx="8" cy="8" r="1" />
          <path d="m3 16 5-5 5 5 3-3 5 5" />
        </>
      )}
    </svg>
  );
}

export function Shortcuts({
  items,
  busy,
  refresh,
}: {
  items: ShortcutConfig[];
  busy: boolean;
  refresh: () => Promise<void>;
}) {
  const [draft, setDraft] = useState<ShortcutConfig | null>(null);
  const [removeId, setRemoveId] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [recommendations, setRecommendations] =
    useState<Recommendations | null>(null);
  const [recentError, setRecentError] = useState("");
  const [loading, setLoading] = useState(true);
  const [externalDrag, setExternalDrag] = useState(false);
  const lock = useRef(false);
  const editorLock = useRef(false);
  const recentLock = useRef(false);
  const alive = useRef(true);
  const current = useRef(items);
  current.current = items;
  const removeRef = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (removeId) removeRef.current?.showModal();
  }, [removeId]);

  async function refreshRecent() {
    if (recentLock.current) return;
    recentLock.current = true;
    setLoading(true);
    try {
      const result = await call<Recommendations>("shortcut_recommendations", {
        excluded: current.current
          .filter((i) => i.kind === "app")
          .map((i) => i.target),
      });
      if (alive.current) {
        setRecommendations(result);
        setRecentError("");
      }
    } catch (e) {
      if (alive.current) setRecentError(message(e));
    } finally {
      recentLock.current = false;
      if (alive.current) setLoading(false);
    }
  }
  useEffect(() => {
    alive.current = true;
    void refreshRecent();
    const timer = setInterval(() => void refreshRecent(), 5000);
    return () => {
      alive.current = false;
      clearInterval(timer);
    };
  }, []);

  async function action(fn: () => Promise<void>) {
    if (lock.current || busy) return;
    lock.current = true;
    setWorking(true);
    setError("");
    setNotice("");
    try {
      await fn();
    } catch (e) {
      setError(message(e));
    } finally {
      lock.current = false;
      setWorking(false);
    }
  }

  async function save(item: ShortcutConfig) {
    if (duplicateShortcut(current.current, item))
      throw new Error("这个入口已经添加过了");
    await call("save_shortcut", { item });
    current.current = current.current.some((i) => i.id === item.id)
      ? current.current.map((i) => (i.id === item.id ? item : i))
      : [...current.current, item];
    await refresh();
  }

  async function addApplications(paths: string[]) {
    let added = 0,
      skipped = 0;
    const failures: string[] = [];
    for (const path of paths) {
      try {
        const app = await call<ApplicationMetadata>("import_application", {
          path,
        });
        const item = { ...app, kind: "app", id: crypto.randomUUID() };
        if (duplicateShortcut(current.current, item)) {
          skipped++;
          continue;
        }
        await save(item);
        added++;
      } catch (e) {
        failures.push(`${path.split(/[\\/]/).pop()}：${message(e)}`);
      }
    }
    if (added || skipped)
      setNotice(
        [
          added ? `已添加 ${added} 个应用` : "",
          skipped ? `${skipped} 个应用已存在` : "",
        ]
          .filter(Boolean)
          .join("，"),
      );
    if (failures.length) setError(failures.join("；"));
  }

  async function drop(paths: string[], iconId?: string) {
    if (busy || lock.current || editorLock.current || removeId) return;
    // A modal only accepts an image dropped onto its icon.
    if (draft && iconId !== draft.id) return;
    await action(async () => {
      if (iconId && paths.length === 1 && !/\.(app|exe)$/i.test(paths[0])) {
        const icon = await call<string>("import_shortcut_icon", {
          path: paths[0],
        });
        if (draft?.id === iconId)
          setDraft((item) =>
            item?.id === iconId ? { ...item, icon_png: icon } : item,
          );
        else {
          const item = current.current.find((i) => i.id === iconId);
          if (item) await save({ ...item, icon_png: icon });
        }
      } else if (!draft) await addApplications(paths);
    });
  }
  const dropRef = useRef(drop);
  dropRef.current = drop;
  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let stop: (() => void) | undefined;
    void getCurrentWebview()
      .onDragDropEvent(({ payload }) => {
        if (disposed) return;
        setExternalDrag(payload.type === "enter" || payload.type === "over");
        if (payload.type === "drop") {
          const element = document.elementFromPoint(
            payload.position.x / window.devicePixelRatio,
            payload.position.y / window.devicePixelRatio,
          );
          void dropRef.current(
            payload.paths,
            element?.closest<HTMLElement>("[data-shortcut-icon]")?.dataset
              .shortcutIcon,
          );
        }
      })
      .then((fn) => {
        if (disposed) fn();
        else stop = fn;
      })
      .catch((e) => setError(message(e)));
    return () => {
      disposed = true;
      stop?.();
    };
  }, []);

  const disabled = busy || working;
  const available =
    recommendations?.items.filter(
      ({ app }) =>
        !items.some((i) => i.kind === "app" && i.target === app.target),
    ) ?? [];
  return (
    <section
      className={`shortcuts-panel${externalDrag ? " external-drag" : ""}`}
    >
      <div className="shortcut-heading">
        <h2>已添加的入口</h2>
        <div className="shortcut-toolbar">
          <button
            disabled={disabled || items.length >= 64}
            onClick={() =>
              void action(async () => {
                const paths = await call<string[]>("choose_applications");
                await addApplications(paths);
              })
            }
          >
            <ShortcutGlyph name="plus" />
            添加应用
          </button>
          <button
            disabled={disabled || items.length >= 64}
            onClick={() => {
              setError("");
              setNotice("");
              setDraft({
                id: crypto.randomUUID(),
                kind: "url",
                name: "",
                target: "https://",
                icon_png: "",
              });
            }}
          >
            <ShortcutGlyph name="globe" />
            添加网址
          </button>
        </div>
      </div>
      {!draft && !removeId && error && (
        <p className="notice error" role="alert">
          {error}
        </p>
      )}
      {notice && (
        <p className="shortcut-feedback" role="status">
          {notice}
        </p>
      )}
      {items.length === 0 && (
        <p className="shortcut-empty">
          添加应用或网址，也可从下方最近使用中选择。
        </p>
      )}
      <ShortcutCatalog
        items={items}
        disabled={disabled || !!draft || !!removeId}
        onEdit={(item) => {
          setDraft({ ...item });
          setError("");
        }}
        onOpen={(id) =>
          void action(async () => {
            await call("open_shortcut", { id });
          })
        }
        onDelete={(id) => {
          setRemoveId(id);
          setError("");
        }}
        onReorder={(ids) =>
          void action(async () => {
            await call("reorder_shortcuts", { ids });
            await refresh();
          })
        }
      />
      <div className="shortcut-heading recent-heading">
        <h2>最近使用 · 点击添加</h2>
        <button
          className="icon-button"
          aria-label="刷新最近应用"
          title="刷新最近应用"
          disabled={loading}
          onClick={() => void refreshRecent()}
        >
          <ShortcutGlyph name="refresh" />
        </button>
      </div>
      {recentError ? (
        <p className="notice error" role="alert">
          {recentError}
          <button disabled={loading} onClick={() => void refreshRecent()}>
            重试
          </button>
        </p>
      ) : loading && !recommendations ? (
        <p className="shortcut-empty">正在读取最近应用…</p>
      ) : recommendations?.supported === false ? (
        <p className="shortcut-empty">
          最近使用目前支持 macOS，可通过「添加应用」选择应用。
        </p>
      ) : !available.length ? (
        <p className="shortcut-empty">
          暂无可添加的最近应用，打开或切换到其他应用后会出现在这里。
        </p>
      ) : (
        <div className="shortcut-recommendations">
          {available.map(({ app }) => (
            <button
              key={app.target}
              className="shortcut-recommendation"
              disabled={disabled || items.length >= 64}
              aria-label={`添加 ${app.name}`}
              onClick={() =>
                void action(async () => {
                  await save({ ...app, kind: "app", id: crypto.randomUUID() });
                })
              }
            >
              <ShortcutIcon icon={app.icon_png} kind="app" />
              <span>{app.name}</span>
              <ShortcutGlyph name="plus" />
            </button>
          ))}
        </div>
      )}
      {draft && (
        <ShortcutEditor
          key={draft.id}
          item={draft}
          onChange={setDraft}
          onClose={() => {
            setDraft(null);
            setError("");
          }}
          disabled={disabled}
          externalError={error}
          onSave={save}
          onWorkingChange={(value) => {
            editorLock.current = value;
          }}
          existing={items.some((i) => i.id === draft.id)}
        />
      )}
      {removeId && (
        <dialog
          ref={removeRef}
          className="modal"
          aria-labelledby="remove-shortcut-title"
          onCancel={(event) => {
            if (disabled) event.preventDefault();
            else setRemoveId(null);
          }}
        >
          <h2 id="remove-shortcut-title">删除入口？</h2>
          <p>
            「{items.find((i) => i.id === removeId)?.name}
            」将从工作台移除，电脑上的应用或网页不受影响。
          </p>
          {error && (
            <p className="notice error" role="alert">
              {error}
            </p>
          )}
          <div className="modal-actions">
            <button disabled={disabled} onClick={() => setRemoveId(null)}>
              取消
            </button>
            <button
              className="danger-button"
              disabled={disabled}
              onClick={() =>
                void action(async () => {
                  await call("remove_shortcut", { id: removeId });
                  setRemoveId(null);
                  await refresh();
                })
              }
            >
              {working ? "删除中…" : "删除"}
            </button>
          </div>
        </dialog>
      )}
    </section>
  );
}

function ShortcutEditor({
  item,
  existing,
  disabled,
  externalError,
  onChange,
  onClose,
  onSave,
  onWorkingChange,
}: {
  item: ShortcutConfig;
  existing: boolean;
  disabled: boolean;
  externalError: string;
  onChange: (item: ShortcutConfig) => void;
  onClose: () => void;
  onSave: (item: ShortcutConfig) => Promise<void>;
  onWorkingChange: (value: boolean) => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const urlRef = useRef<HTMLInputElement>(null);
  const latest = useRef(item);
  latest.current = item;
  const mounted = useRef(true);
  const lock = useRef(false);
  const [working, setWorking] = useState(false);
  const [fetching, setFetching] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  useEffect(() => {
    mounted.current = true;
    ref.current?.showModal();
    if (!existing && item.kind === "url") {
      urlRef.current?.focus();
      urlRef.current?.setSelectionRange(item.target.length, item.target.length);
    }
    return () => {
      mounted.current = false;
    };
  }, []);

  async function action(fn: () => Promise<void>) {
    if (lock.current || disabled) return;
    lock.current = true;
    onWorkingChange(true);
    setWorking(true);
    setError("");
    try {
      await fn();
    } catch (e) {
      if (mounted.current) setError(message(e));
    } finally {
      lock.current = false;
      onWorkingChange(false);
      if (mounted.current) setWorking(false);
    }
  }
  async function fetchInfo() {
    if (fetching) return;
    const requested = latest.current;
    setFetching(true);
    setError("");
    setNotice("");
    try {
      const info = await call<WebsiteInfo>("shortcut_website_info", {
        url: requested.target.trim(),
      });
      if (!mounted.current || latest.current.target !== requested.target)
        return;
      onChange(applyWebsiteInfo(latest.current, requested, info));
      setNotice(
        info.warning ||
          (info.title && info.icon ? "已获取网站名称和图标" : "已获取网站信息"),
      );
    } catch (e) {
      if (mounted.current && latest.current.target === requested.target)
        setError(message(e));
    } finally {
      if (mounted.current) setFetching(false);
    }
  }
  const blocked = disabled || working;
  return (
    <dialog
      ref={ref}
      className="modal shortcut-editor"
      aria-labelledby="shortcut-editor-title"
      onCancel={(event) => {
        if (blocked) event.preventDefault();
        else onClose();
      }}
      onClick={(event) => {
        if (event.target !== event.currentTarget || blocked) return;
        const bounds = event.currentTarget.getBoundingClientRect();
        if (
          event.clientX < bounds.left ||
          event.clientX > bounds.right ||
          event.clientY < bounds.top ||
          event.clientY > bounds.bottom
        )
          onClose();
      }}
    >
      <form
        className="shortcut-form"
        onSubmit={(event) => {
          event.preventDefault();
          void action(async () => {
            const next = {
              ...latest.current,
              name: latest.current.name.trim(),
              target: latest.current.target.trim(),
            };
            if (next.kind === "url" && !canFetchWebsiteInfo(next.target))
              throw new Error("请填写完整的 HTTP/HTTPS 网址");
            await onSave(next);
            onClose();
          });
        }}
      >
        <div className="shortcut-heading">
          <h2 id="shortcut-editor-title">
            {item.kind === "url"
              ? existing
                ? "编辑网址"
                : "添加网址"
              : "编辑应用"}
          </h2>
          <button
            className="icon-button"
            type="button"
            aria-label="关闭配置"
            disabled={blocked}
            onClick={onClose}
          >
            <ShortcutGlyph name="close" />
          </button>
        </div>
        <fieldset disabled={blocked}>
          <div className="shortcut-identity">
            <button
              type="button"
              className="shortcut-icon-picker"
              data-shortcut-icon={item.id}
              aria-label="更换图标"
              title="选择图片，或将图片拖到这里"
              onClick={() =>
                void action(async () => {
                  const icon = await call<string | null>(
                    "choose_shortcut_icon",
                  );
                  if (icon && mounted.current)
                    onChange({ ...latest.current, icon_png: icon });
                })
              }
            >
              <ShortcutIcon
                key={item.icon_png}
                icon={item.icon_png}
                kind={item.kind}
              />
              <span className="icon-edit">
                <ShortcutGlyph name="image" />
              </span>
            </button>
            <label>
              名称
              <input
                autoFocus={existing || item.kind === "app"}
                required
                maxLength={64}
                placeholder={item.kind === "url" ? "网站名称" : "应用名称"}
                value={item.name}
                onChange={(e) => onChange({ ...item, name: e.target.value })}
              />
            </label>
          </div>
          {item.kind === "url" ? (
            <>
              <label>
                网址
                <input
                  ref={urlRef}
                  required
                  maxLength={4096}
                  spellCheck={false}
                  autoCapitalize="off"
                  placeholder="https://example.com"
                  value={item.target}
                  onChange={(e) => {
                    onChange({ ...item, target: e.target.value });
                    setError("");
                    setNotice("");
                  }}
                />
              </label>
              <div className="website-info-actions">
                <button
                  type="button"
                  disabled={fetching || !canFetchWebsiteInfo(item.target)}
                  onClick={() => void fetchInfo()}
                >
                  <ShortcutGlyph name="refresh" />
                  {fetching ? "正在获取…" : "获取网站名称和图标"}
                </button>
              </div>
            </>
          ) : (
            <div className="shortcut-path-row">
              <span title={item.target}>{item.target}</span>
              <button
                type="button"
                onClick={() =>
                  void action(async () => {
                    const app = await call<ApplicationMetadata | null>(
                      "choose_application",
                    );
                    if (app && mounted.current)
                      onChange({ ...latest.current, ...app });
                  })
                }
              >
                更换应用
              </button>
            </div>
          )}
          {item.icon_png && (
            <button
              className="text-button reset-shortcut-icon"
              type="button"
              onClick={() => onChange({ ...item, icon_png: "" })}
            >
              恢复默认图标
            </button>
          )}
          {notice && (
            <p className="shortcut-feedback" role="status">
              {notice}
            </p>
          )}
          {(error || externalError) && (
            <p className="notice error" role="alert">
              {error || externalError}
            </p>
          )}
          <div className="modal-actions">
            <button type="button" onClick={onClose}>
              取消
            </button>
            <button type="submit" className="primary">
              {working ? "保存中…" : "保存入口"}
            </button>
          </div>
        </fieldset>
      </form>
    </dialog>
  );
}
