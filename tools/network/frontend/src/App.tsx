import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkToolApp } from "./features/network-tool/NetworkToolApp";
import { useNetworkToolModel } from "./features/network-tool/hooks/useNetworkToolModel";
import { usePluginMetadata } from "./features/app-tool/usePluginMetadata";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = usePluginMetadata();
  const model = useNetworkToolModel(client, metadata, connected, revision);
  return (
    <div className="window-frame">
      <NetworkToolApp model={model} />
    </div>
  );
}
