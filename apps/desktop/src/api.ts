import { invoke, isTauri } from "@tauri-apps/api/core";

export interface Device {
  id: string;
  name: string;
  paired_at: number;
}
export interface Status {
  name: string;
  host_id: string;
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
      new Error("请在 Desklet 桌面应用中连接设备。浏览器只能预览界面。"),
    );
  return invoke<T>(command, args);
}
