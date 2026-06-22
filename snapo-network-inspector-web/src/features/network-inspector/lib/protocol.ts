import type { InspectorRecord, ServerId } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";

export const supportedProtocolVersion = 1;

export function serverHasProtocolWarning(server: SnapOServer | null): server is SnapOServer {
  return server?.isProtocolNewerThanSupported === true || server?.isProtocolOlderThanSupported === true;
}

export function unsupportedLegacyProtocolMessage(server: SnapOServer | null): string {
  const protocolText = server?.protocolVersion == null ? "not reported" : `${server.protocolVersion}`;
  return `App reports protocol v${protocolText}. This Snap-O Desktop supports protocol v${supportedProtocolVersion} and newer.`;
}

export function isUnsupportedLegacyProtocolRequestSelection(
  record: InspectorRecord | null,
  selectedServer: SnapOServer | null
): boolean {
  if (record?.kind !== "request" || selectedServer?.isProtocolOlderThanSupported !== true) return false;
  return serverIdsEqual(record.server, selectedServer);
}

function serverIdsEqual(left: ServerId, right: Pick<SnapOServer, "deviceId" | "socketName">): boolean {
  return left.deviceId === right.deviceId && left.socketName === right.socketName;
}
