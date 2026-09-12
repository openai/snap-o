import { useEffect, useState } from "preact/hooks";
import type { Host, ToolConnection } from "@snap-o/tool-host";

export type ToolMetadata = Pick<ToolConnection, "protocolVersion" | "processIdentity">;

export function useHostConnection(host: Host) {
  const [state, setState] = useState(() => ({
    connected: host.connection !== null,
    revision: 0,
    metadata: host.connection as ToolMetadata | null
  }));
  useEffect(
    () =>
      host.onConnection((connection) => {
        // Keep the last protocol and process identity while showing cached data offline.
        setState((current) => ({
          connected: connection !== null,
          revision: current.revision + 1,
          metadata: connection ?? current.metadata
        }));
      }),
    [host]
  );
  return state;
}
