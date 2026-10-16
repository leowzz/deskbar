import { invoke, isTauri } from "@tauri-apps/api/core";

export interface DeviceDisplay {
  width: number;
  height: number;
  text_scale: number;
  dark: boolean;
  page_id: string;
  layout_revision: number;
  seen_at: number;
}

export interface Device {
  id: string;
  name: string;
  paired_at: number;
  permissions: Permissions;
  layout_revision: number;
  display: DeviceDisplay | null;
}
export interface Status {
  name: string;
  host_id: string;
  workbench: WorkbenchData;
  shortcuts: ShortcutConfig[];
  devices: Device[];
  pending: { id: string; name: string; expires_at: number } | null;
  addresses: string[];
  discovery_warning: string | null;
  usage_config: UsageConfig | null;
}
export interface Invitation {
  uri: string;
  expires_at: number;
}

export function call<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (!isTauri())
    return Promise.reject(
      new Error("请在 DeskBar 连接助手中连接设备。浏览器只能预览界面。"),
    );
  return invoke<T>(command, args);
}

export interface Permissions {
  sessions: boolean;
  quota: boolean;
  api_usage: boolean;
  shortcuts: boolean;
  open: boolean;
}
export interface ShortcutConfig {
  id: string;
  name: string;
  kind: string;
  target: string;
  icon_png: string;
}
export interface ApplicationMetadata {
  target: string;
  name: string;
  icon_png: string;
}
export interface SourceState {
  source_id: string;
  health: string;
  message: string;
  observed_at: number;
  fresh_until: number;
}
export interface UsageConfig {
  base_url: string;
  email: string;
  timezone: string;
}
export interface ApiUsage {
  id: string;
  label: string;
  actual_cost_micros: number;
  currency: string;
  token_count: number;
  tpm: number;
  window_start: number;
  window_end: number;
}
export interface WorkbenchData {
  api_usage: ApiUsage[];
  sources: SourceState[];
  session_total: number;
  sessions: {
    session_id: string;
    title: string;
    project: string;
    status: string;
  }[];
  quotas: {
    id: string;
    label: string;
    remaining_percent: number;
    resets_at: number;
  }[];
}
