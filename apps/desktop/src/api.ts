import { invoke, isTauri } from "@tauri-apps/api/core";

export interface Device {
  id: string;
  name: string;
  paired_at: number;
  permissions: Permissions;
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
      new Error("请在 Desklet 连接助手中连接设备。浏览器只能预览界面。"),
    );
  return invoke<T>(command, args);
}

export interface Permissions {
  sessions: boolean;
  quota: boolean;
  shortcuts: boolean;
  open: boolean;
}
export interface ShortcutConfig {
  id: string;
  name: string;
  kind: string;
  target: string;
}
export interface SourceState {
  source_id: string;
  health: string;
  message: string;
  observed_at: number;
  fresh_until: number;
}
export interface WorkbenchData {
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
