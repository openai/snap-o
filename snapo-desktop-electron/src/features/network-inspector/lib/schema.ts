import type { InspectorRecord, ServerId } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";

export const supportedSchemaVersion = 3;

export function serverHasSchemaWarning(server: SnapOServer | null): server is SnapOServer {
  return server?.isSchemaNewerThanSupported === true || server?.isSchemaOlderThanSupported === true;
}

export function unsupportedLegacySchemaMessage(server: SnapOServer | null): string {
  const schemaText = server?.schemaVersion == null ? "not reported" : `${server.schemaVersion}`;
  return `App reports schema v${schemaText}. This Snap-O Desktop supports schema v${supportedSchemaVersion} and newer. Use Snap-O 0.19.0 or older to inspect this app server.`;
}

export function isUnsupportedLegacySchemaRequestSelection(
  record: InspectorRecord | null,
  selectedServer: SnapOServer | null
): boolean {
  if (record?.kind !== "request" || selectedServer?.isSchemaOlderThanSupported !== true) return false;
  return serverIdsEqual(record.server, selectedServer);
}

function serverIdsEqual(left: ServerId, right: Pick<SnapOServer, "deviceId" | "socketName">): boolean {
  return left.deviceId === right.deviceId && left.socketName === right.socketName;
}
