import { useMemo } from "preact/hooks";
import { host } from "@snap-o/host";
import { useHostConnection } from "../../useHostConnection";

export interface InspectorMetadata {
  name: string;
  packageName: string;
  processName?: string;
  protocolVersion: number;
  pid?: number;
  processIdentity?: string;
}

export function useInspectorMetadata() {
  const connection = useHostConnection(host);
  const manifest = host.manifest;
  const inspector = host.inspector;
  const metadata = useMemo<InspectorMetadata | null>(() => {
    if (!manifest?.app) return null;
    return {
      name: manifest.app.name,
      packageName: manifest.app.packageName,
      processName: manifest.processName,
      protocolVersion: inspector?.protocolVersion ?? 0,
      pid: manifest.pid,
      processIdentity: manifest.processIdentity
    };
  }, [manifest, inspector]);
  return {
    connected: connection.connected && metadata !== null,
    revision: connection.revision,
    metadata
  };
}
