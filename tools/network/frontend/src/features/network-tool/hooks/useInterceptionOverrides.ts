import type { ToolConnection } from "@snap-o/tool-host";
import { useEffect, useState } from "preact/hooks";
import { observeInterception, type InterceptionState } from "../../../network/interception";

export function useInterceptionOverrides(connection: ToolConnection | null): InterceptionState {
  const [observed, setObserved] = useState<{
    connection: ToolConnection;
    state: InterceptionState;
  } | null>(null);

  useEffect(() => {
    if (!connection) return;
    return observeInterception(connection, (state) => setObserved({ connection, state }));
  }, [connection]);

  if (!connection || connection.signal.aborted) return { status: "disconnected" };
  // A new selection must not render the previous app's registrations before effect cleanup.
  return observed?.connection === connection ? observed.state : { status: "connecting" };
}
