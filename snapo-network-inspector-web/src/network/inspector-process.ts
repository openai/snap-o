import type { AppInspectorKind, InspectorServerReference } from "./bridge-types";

export function inspectorProcessId(kind: AppInspectorKind, server: InspectorServerReference): string {
  const prefix = `snapo_${kind}_`;
  const suffix = server.socketName.startsWith(prefix) ? server.socketName.slice(prefix.length) : "";
  const pid = /^\d+$/.test(suffix) ? Number(suffix) : NaN;
  return Number.isSafeInteger(pid) && pid > 0
    ? `${server.deviceId}:pid:${pid}`
    : `${server.deviceId}:socket:${server.socketName}`;
}
