import type { DebugInspectorPreset, SnapOServer } from "../../../network/bridge-types";

const supportedProtocolVersion = 1;

export function applyDebugInspectorPreset(
  servers: SnapOServer[],
  selectedServer: Pick<SnapOServer, "deviceId" | "socketName"> | null,
  preset: DebugInspectorPreset
): SnapOServer[] {
  if (preset === "live" || selectedServer == null) return servers;

  const selectedIndex = servers.findIndex((server) => serverMatches(server, selectedServer));
  if (selectedIndex < 0) return servers;

  const current = servers[selectedIndex];
  const nextServers = [...servers];
  switch (preset) {
    case "protocolOlder":
      nextServers[selectedIndex] = {
        ...current,
        protocolVersion: supportedProtocolVersion - 1,
        isProtocolNewerThanSupported: false,
        isProtocolOlderThanSupported: true
      };
      return nextServers;
    case "protocolNewer":
      nextServers[selectedIndex] = {
        ...current,
        protocolVersion: supportedProtocolVersion + 1,
        isProtocolNewerThanSupported: true,
        isProtocolOlderThanSupported: false
      };
      return nextServers;
  }
}

function serverMatches(
  left: Pick<SnapOServer, "deviceId" | "socketName">,
  right: Pick<SnapOServer, "deviceId" | "socketName">
): boolean {
  return left.deviceId === right.deviceId && left.socketName === right.socketName;
}
