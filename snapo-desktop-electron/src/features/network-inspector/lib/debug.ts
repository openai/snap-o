import type { DebugInspectorPreset, SnapOServer } from "../../../network/bridge-types";

const supportedSchemaVersion = 3;

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
    case "schemaOlder":
      nextServers[selectedIndex] = {
        ...current,
        schemaVersion: supportedSchemaVersion - 1,
        isSchemaNewerThanSupported: false,
        isSchemaOlderThanSupported: true
      };
      return nextServers;
    case "schemaNewer":
      nextServers[selectedIndex] = {
        ...current,
        schemaVersion: supportedSchemaVersion + 1,
        isSchemaNewerThanSupported: true,
        isSchemaOlderThanSupported: false
      };
      return nextServers;
    case "missingNetworkFeature":
      nextServers[selectedIndex] = {
        ...current,
        hasHello: true,
        features: current.features.filter((feature) => feature !== "network")
      };
      return nextServers;
    case "replacementProcess":
      return withReplacementProcess(nextServers, selectedIndex);
  }
}

function withReplacementProcess(servers: SnapOServer[], selectedIndex: number): SnapOServer[] {
  const selected = servers[selectedIndex];
  const replacementSocketName = `${selected.socketName}:debug-replacement`;
  const replacement: SnapOServer = {
    ...selected,
    server: `${selected.deviceId}:${replacementSocketName}`,
    socketName: replacementSocketName,
    isConnected: true,
    pid: selected.pid == null ? 99999 : selected.pid + 1
  };
  const nextServers = [...servers];
  nextServers[selectedIndex] = { ...selected, isConnected: false };
  nextServers.push(replacement);
  return nextServers.sort((left, right) => {
    const device = left.deviceId.localeCompare(right.deviceId);
    return device !== 0 ? device : left.socketName.localeCompare(right.socketName);
  });
}

function serverMatches(
  left: Pick<SnapOServer, "deviceId" | "socketName">,
  right: Pick<SnapOServer, "deviceId" | "socketName">
): boolean {
  return left.deviceId === right.deviceId && left.socketName === right.socketName;
}
