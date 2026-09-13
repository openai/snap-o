import { useEffect, useState } from "preact/hooks";
import type { Host, ToolConnection } from "@snap-o/tool-host";

export function useHostConnection(host: Host) {
  const [connection, setConnection] = useState<ToolConnection | null>(null);
  useEffect(() => host.onConnection(setConnection), [host]);
  return connection;
}
