import { useEffect, useState } from "preact/hooks";
import type { Host } from "@snap-o/tool-host";

export function useHostConnection(host: Host): { connected: boolean; revision: number } {
  const [state, setState] = useState(() => ({ connected: host.connected, revision: 0 }));
  useEffect(
    () =>
      host.onConnection(() => {
        setState((current) => ({ connected: host.connected, revision: current.revision + 1 }));
      }),
    [host]
  );
  return state;
}
