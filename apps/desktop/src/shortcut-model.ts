import type { ShortcutConfig } from "./api";

export type WebsiteInfo = {
  title: string;
  icon: string;
  warning: string | null;
};

export function canFetchWebsiteInfo(target: string) {
  try {
    const url = new URL(target.trim());
    return (
      ["http:", "https:"].includes(url.protocol) &&
      !!url.hostname &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
}

// Keep edits made while the request was in flight, including a manual icon.
export function applyWebsiteInfo(
  current: ShortcutConfig,
  requested: ShortcutConfig,
  info: WebsiteInfo,
): ShortcutConfig {
  if (current.id !== requested.id || current.target !== requested.target)
    return current;
  return {
    ...current,
    name:
      !current.name.trim() && current.name === requested.name && info.title
        ? info.title
        : current.name,
    icon_png:
      current.icon_png === requested.icon_png && info.icon
        ? info.icon
        : current.icon_png,
  };
}

export function duplicateShortcut(
  items: ShortcutConfig[],
  item: ShortcutConfig,
) {
  return items.some(
    (other) =>
      other.id !== item.id &&
      other.kind === item.kind &&
      other.target === item.target,
  );
}
