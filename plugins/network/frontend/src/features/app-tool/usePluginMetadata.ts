import { useMemo } from "preact/hooks";
import { host } from "@snap-o/plugin-host";
import { useHostConnection } from "../../useHostConnection";

export interface PluginMetadata {
  name: string;
  packageName: string;
  processName?: string;
  protocolVersion: number;
  pid?: number;
  processIdentity: string;
}

export function usePluginMetadata() {
  const connection = useHostConnection(host);
  const manifest = host.manifest;
  const tool = host.plugin;
  const metadata = useMemo<PluginMetadata | null>(() => {
    if (!manifest?.app) return null;
    return {
      name: manifest.app.name,
      packageName: manifest.app.packageName,
      processName: manifest.processName,
      protocolVersion: tool?.protocolVersion ?? 0,
      pid: manifest.pid,
      processIdentity: manifest.processIdentity
    };
  }, [manifest, tool]);
  return {
    connected: connection.connected && metadata !== null,
    revision: connection.revision,
    metadata
  };
}
