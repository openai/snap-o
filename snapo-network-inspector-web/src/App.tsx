import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import type { SnapOServer } from "./network/bridge-types";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { supportedProtocolVersion } from "./features/network-inspector/lib/protocol";
import { useInspectorMetadata } from "./features/app-inspector/useInspectorMetadata";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = useInspectorMetadata();
  const server = useMemo<SnapOServer | null>(
    () =>
      metadata && {
        server: "network",
        deviceId: "inspector",
        socketName: "network",
        deviceDisplayTitle: "",
        displayName: metadata.name,
        isConnected: connected,
        hasAppInfo: true,
        protocolVersion: metadata.protocolVersion,
        isProtocolNewerThanSupported: metadata.protocolVersion > supportedProtocolVersion,
        isProtocolOlderThanSupported: metadata.protocolVersion < supportedProtocolVersion,
        packageName: metadata.packageName,
        appName: metadata.name,
        pid: metadata.pid,
        instanceId: `${metadata.serverStartWallMs}:${metadata.serverStartMonoNs}`
      },
    [connected, metadata]
  );
  const model = useNetworkInspectorModel(client, server, connected, revision);
  return (
    <div className="window-frame">
      <NetworkInspectorApp model={model} />
    </div>
  );
}
