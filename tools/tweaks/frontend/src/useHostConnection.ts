import { useEffect, useState } from "preact/hooks";
import type { Host, ToolConnection } from "@snap-o/tool-host";

export type ToolMetadata = Pick<ToolConnection, "processIdentity"> & { protocolVersion: number };

export function useHostConnection(host: Host) {
  const [state, setState] = useState({
    connected: false,
    revision: 0,
    metadata: null as ToolMetadata | null,
    error: null as string | null
  });
  useEffect(() => {
    let cancel = () => {};
    const unsubscribe = host.onConnection((connection) => {
      cancel();
      setState((current) => ({
        connected: false,
        revision: current.revision + 1,
        metadata:
          !connection || connection.processIdentity === current.metadata?.processIdentity ? current.metadata : null,
        error: null
      }));
      if (!connection) return;
      const controller = new AbortController();
      cancel = () => controller.abort();
      const signal = AbortSignal.any([connection.signal, controller.signal, AbortSignal.timeout(10_000)]);
      void fetch(new URL("tweaks/protocol", connection.baseURL), { signal })
        .then(async (response) => {
          if (!response.ok)
            throw new Error(`Protocol request failed (${response.status}). Update the Android library.`);
          const payload: unknown = await response.json();
          if (
            !payload ||
            typeof payload !== "object" ||
            !("version" in payload) ||
            typeof payload.version !== "number" ||
            !Number.isInteger(payload.version) ||
            payload.version <= 0
          ) {
            throw new Error("The Android app returned an invalid Tweaks protocol version.");
          }
          const protocolVersion = payload.version;
          if (signal.aborted) return;
          setState((current) => ({
            connected: true,
            revision: current.revision + 1,
            metadata: { processIdentity: connection.processIdentity, protocolVersion },
            error: null
          }));
        })
        .catch((error: unknown) => {
          if (controller.signal.aborted || connection.signal.aborted) return;
          setState((current) => ({
            ...current,
            connected: false,
            error: error instanceof Error ? error.message : "Unable to check the Tweaks protocol."
          }));
        });
    });
    return () => {
      cancel();
      unsubscribe();
    };
  }, [host]);
  return state;
}
