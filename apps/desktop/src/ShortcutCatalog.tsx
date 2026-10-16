import { useEffect, useRef, useState, type PointerEvent } from "react";
import { createPortal } from "react-dom";
import { type ShortcutConfig } from "./api";

export function ShortcutIcon({ icon, kind }: { icon: string; kind: string }) {
  const [failed, setFailed] = useState(false);
  return (
    <span className="shortcut-icon" aria-hidden="true">
      {icon && !failed ? (
        <img
          src={`data:image/png;base64,${icon}`}
          alt=""
          draggable={false}
          onError={() => setFailed(true)}
        />
      ) : (
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.65"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          {kind === "app" ? (
            <>
              <rect x="3" y="3" width="7" height="7" rx="1.5" />
              <rect x="14" y="3" width="7" height="7" rx="1.5" />
              <rect x="3" y="14" width="7" height="7" rx="1.5" />
              <rect x="14" y="14" width="7" height="7" rx="1.5" />
            </>
          ) : (
            <>
              <circle cx="12" cy="12" r="9" />
              <ellipse cx="12" cy="12" rx="4" ry="9" />
              <path d="M3 12h18" />
            </>
          )}
        </svg>
      )}
    </span>
  );
}

type Menu = { id: string; x: number; y: number };
type Gesture = {
  id: string;
  x: number;
  y: number;
  active: boolean;
  over: string | null;
};

export function ShortcutCatalog({
  items,
  disabled,
  onEdit,
  onDelete,
  onReorder,
}: {
  items: ShortcutConfig[];
  disabled: boolean;
  onEdit: (item: ShortcutConfig) => void;
  onDelete: (id: string) => void;
  onReorder: (ids: string[]) => void;
}) {
  const [menu, setMenu] = useState<Menu | null>(null);
  const [drag, setDrag] = useState<{ id: string; over: string | null } | null>(
    null,
  );
  const menuRef = useRef<HTMLDivElement>(null);
  const catalogRef = useRef<HTMLDivElement>(null);
  const gesture = useRef<Gesture | null>(null);

  useEffect(() => {
    if (!disabled) return;
    gesture.current = null;
    setDrag(null);
    setMenu(null);
  }, [disabled]);

  function closeMenu(restoreFocus = false) {
    if (restoreFocus && menu)
      [
        ...(catalogRef.current?.querySelectorAll<HTMLButtonElement>(
          "[data-shortcut-id]",
        ) ?? []),
      ]
        .find((item) => item.dataset.shortcutId === menu.id)
        ?.focus();
    setMenu(null);
  }

  useEffect(() => {
    if (!menu) return;
    menuRef.current?.querySelector<HTMLButtonElement>("button")?.focus();
    const dismiss = (event: globalThis.PointerEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) setMenu(null);
    };
    const close = () => setMenu(null);
    document.addEventListener("pointerdown", dismiss);
    window.addEventListener("resize", close);
    window.addEventListener("scroll", close, true);
    return () => {
      document.removeEventListener("pointerdown", dismiss);
      window.removeEventListener("resize", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [menu]);

  function context(id: string, x: number, y: number) {
    if (disabled || gesture.current?.active) return;
    setMenu({
      id,
      x: Math.max(8, Math.min(x, window.innerWidth - 176)),
      y: Math.max(8, Math.min(y, window.innerHeight - 96)),
    });
  }

  function moveDrag(event: PointerEvent<HTMLButtonElement>) {
    const current = gesture.current;
    if (!current || disabled) return;
    if (
      !current.active &&
      Math.hypot(event.clientX - current.x, event.clientY - current.y) < 7
    )
      return;
    current.active = true;
    if (event.clientY > window.innerHeight - 32) window.scrollBy(0, 16);
    if (event.clientY < 32) window.scrollBy(0, -16);
    const target = document
      .elementFromPoint(event.clientX, event.clientY)
      ?.closest<HTMLElement>("[data-shortcut-id]");
    current.over =
      target && catalogRef.current?.contains(target)
        ? (target.dataset.shortcutId ?? null)
        : null;
    setDrag({ id: current.id, over: current.over });
  }

  function endDrag(event: PointerEvent<HTMLButtonElement>, cancelled = false) {
    const current = gesture.current;
    gesture.current = null;
    setDrag(null);
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
    if (!current?.active || cancelled || disabled || !current.over) return;
    const ids = items.map((item) => item.id);
    const from = ids.indexOf(current.id);
    const to = ids.indexOf(current.over);
    if (from < 0 || to < 0 || from === to) return;
    ids.splice(to, 0, ids.splice(from, 1)[0]);
    onReorder(ids);
  }

  const selected = menu && items.find((item) => item.id === menu.id);
  return (
    <>
      <div
        ref={catalogRef}
        className="shortcut-catalog"
        aria-label="快捷入口"
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            gesture.current = null;
            setDrag(null);
          }
        }}
      >
        {items.map((item) => (
          <button
            type="button"
            key={item.id}
            data-shortcut-id={item.id}
            className={`shortcut-tile${drag?.id === item.id ? " dragging" : ""}${drag?.over === item.id && drag.id !== item.id ? " drop-target" : ""}`}
            disabled={disabled}
            aria-haspopup="menu"
            aria-expanded={menu?.id === item.id}
            title={`${item.kind === "app" ? "应用" : "网页"} · ${item.target}`}
            onContextMenu={(event) => {
              event.preventDefault();
              context(item.id, event.clientX, event.clientY);
            }}
            onKeyDown={(event) => {
              if (
                event.key === "ContextMenu" ||
                (event.shiftKey && event.key === "F10")
              ) {
                event.preventDefault();
                const bounds = event.currentTarget.getBoundingClientRect();
                context(item.id, bounds.left, bounds.bottom);
              }
              if (
                event.altKey &&
                ["ArrowLeft", "ArrowRight"].includes(event.key)
              ) {
                event.preventDefault();
                const ids = items.map((shortcut) => shortcut.id);
                const from = ids.indexOf(item.id);
                const to = from + (event.key === "ArrowLeft" ? -1 : 1);
                if (to >= 0 && to < ids.length) {
                  ids.splice(to, 0, ids.splice(from, 1)[0]);
                  onReorder(ids);
                }
              }
            }}
            onClick={(event) => {
              if (event.detail !== 0) return;
              const bounds = event.currentTarget.getBoundingClientRect();
              context(item.id, bounds.left, bounds.bottom);
            }}
            onDragStart={(event) => event.preventDefault()}
            onPointerDown={(event) => {
              if (event.button !== 0 || disabled) return;
              setMenu(null);
              gesture.current = {
                id: item.id,
                x: event.clientX,
                y: event.clientY,
                active: false,
                over: item.id,
              };
              event.currentTarget.setPointerCapture(event.pointerId);
            }}
            onPointerMove={moveDrag}
            onPointerUp={(event) => endDrag(event)}
            onPointerCancel={(event) => endDrag(event, true)}
            onLostPointerCapture={(event) => endDrag(event, true)}
          >
            <ShortcutIcon
              key={item.icon_png}
              icon={item.icon_png}
              kind={item.kind}
            />
            <span className="shortcut-name">{item.name}</span>
          </button>
        ))}
      </div>
      {menu &&
        selected &&
        !disabled &&
        createPortal(
          <div
            ref={menuRef}
            className="shortcut-menu"
            role="menu"
            aria-label={`${selected.name}的操作`}
            style={{ left: menu.x, top: menu.y }}
            onContextMenu={(event) => event.preventDefault()}
            onKeyDown={(event) => {
              const buttons = [
                ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
                  "button",
                ),
              ];
              const index = buttons.indexOf(
                document.activeElement as HTMLButtonElement,
              );
              if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
                event.preventDefault();
                buttons[
                  event.key === "Home"
                    ? 0
                    : event.key === "End"
                      ? buttons.length - 1
                      : (index +
                          (event.key === "ArrowDown" ? 1 : -1) +
                          buttons.length) %
                        buttons.length
                ]?.focus();
              }
              if (event.key === "Escape" || event.key === "Tab") {
                if (event.key === "Escape") event.preventDefault();
                closeMenu(true);
              }
            }}
          >
            <button
              role="menuitem"
              onClick={() => {
                closeMenu();
                onEdit(selected);
              }}
            >
              编辑
            </button>
            <button
              role="menuitem"
              className="danger-text"
              onClick={() => {
                closeMenu();
                onDelete(selected.id);
              }}
            >
              删除
            </button>
          </div>,
          document.body,
        )}
    </>
  );
}
