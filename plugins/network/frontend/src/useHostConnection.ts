import { useEffect, useState } from "preact/hooks";
import type { Host } from "@snap-o/plugin-host";

export function useHostConnection(host: Host): { connected: boolean; revision: number } {
  const [state, setState] = useState(() => ({ connected: host.connected, revision: 0 }));
  useEffect(() => {
    const update = () => setState((current) => ({ connected: host.connected, revision: current.revision + 1 }));
    host.addEventListener("connection", update);
    update();
    return () => host.removeEventListener("connection", update);
  }, [host]);
  return state;
}
