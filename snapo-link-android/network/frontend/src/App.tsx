import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { useInspectorMetadata } from "./features/app-inspector/useInspectorMetadata";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = useInspectorMetadata();
  const model = useNetworkInspectorModel(client, metadata, connected, revision);
  return (
    <div className="window-frame">
      <NetworkInspectorApp model={model} />
    </div>
  );
}
