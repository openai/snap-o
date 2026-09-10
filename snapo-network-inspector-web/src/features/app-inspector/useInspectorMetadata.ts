import { useEffect, useState } from "preact/hooks";
import { host } from "../../host";
import { useHostConnection } from "../../host/useHostConnection";

export interface InspectorMetadata {
  name: string;
  packageName: string;
  processName?: string;
  protocolVersion: number;
  pid?: number;
  serverStartWallMs?: number;
  serverStartMonoNs?: number;
}

export function useInspectorMetadata() {
  const connection = useHostConnection(host);
  const [snapshot, setSnapshot] = useState<{ revision: number; metadata: InspectorMetadata } | null>(null);
  useEffect(() => {
    const baseURL = host.baseURL;
    if (!connection.connected || !baseURL) return;
    const controller = new AbortController();
    let retry: ReturnType<typeof setTimeout> | undefined;
    let delay = 250;
    const load = async () => {
      try {
        const response = await fetch(new URL(".snap-o/info", baseURL), {
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5_000)]),
          redirect: "error",
          cache: "no-store"
        });
        if (!response.ok) throw new Error("Unable to read app metadata.");
        const metadata = (await response.json()) as InspectorMetadata;
        if (
          !metadata ||
          typeof metadata.name !== "string" ||
          typeof metadata.packageName !== "string" ||
          !Number.isInteger(metadata.protocolVersion)
        )
          throw new Error("Invalid app metadata.");
        if (!controller.signal.aborted) setSnapshot({ revision: connection.revision, metadata });
      } catch {
        if (controller.signal.aborted) return;
        retry = setTimeout(() => void load(), delay);
        delay = Math.min(delay * 2, 4_000);
      }
    };
    void load();
    return () => {
      controller.abort();
      clearTimeout(retry);
    };
  }, [connection.connected, connection.revision]);
  return {
    connected: connection.connected && snapshot?.revision === connection.revision,
    revision: connection.revision,
    metadata: snapshot?.metadata ?? null
  };
}
