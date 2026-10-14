import type { ToolConnection } from "@snap-o/tool-host";
import { useEffect, useState } from "preact/hooks";
import { observeInterception, type InterceptionRunner } from "../../../network/interception";

export function useInterceptionOverrides(connection: ToolConnection | null): InterceptionRunner[] {
  const [observed, setObserved] = useState<{
    connection: ToolConnection;
    runners: InterceptionRunner[];
  } | null>(null);

  useEffect(() => {
    if (!connection) return;
    return observeInterception(connection, (runners) => setObserved({ connection, runners }));
  }, [connection]);

  // A new selection must not render the previous app's registrations before effect cleanup.
  if (!connection || connection.signal.aborted || observed?.connection !== connection) return [];
  return observed.runners;
}
