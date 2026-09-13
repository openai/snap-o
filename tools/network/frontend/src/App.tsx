import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkToolApp } from "./features/network-tool/NetworkToolApp";
import { useNetworkToolModel } from "./features/network-tool/hooks/useNetworkToolModel";
import { host } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const connection = useHostConnection(host);
  const model = useNetworkToolModel(client, connection);
  return (
    <div className="window-frame">
      <NetworkToolApp model={model} />
    </div>
  );
}
