import type { ToolConnection } from "@snap-o/tool-host";

export interface InterceptionRoute {
  id: string;
  method: string;
  path: string;
}

export interface InterceptionRunner {
  id: string;
  routes: InterceptionRoute[];
}

export function observeInterception(
  connection: ToolConnection,
  onRunners: (runners: InterceptionRunner[]) => void
): () => void {
  if (connection.signal.aborted) return () => {};

  let disposed = false;
  let stream: EventSource | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  let retryDelayMs = 250;
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    clearTimeout(retryTimer);
    stream?.close();
    connection.signal.removeEventListener("abort", disconnected);
  };
  const disconnected = () => {
    dispose();
    onRunners([]);
  };
  connection.signal.addEventListener("abort", disconnected, { once: true });

  function openStream() {
    if (disposed) return;
    try {
      const current = new EventSource("/api/interception");
      stream = current;
      current.addEventListener("message", (event) => {
        if (disposed || stream !== current) return;
        try {
          onRunners(parseSnapshot(event.data));
          retryDelayMs = 250;
        } catch {
          dispose();
          onRunners([]);
        }
      });
      current.addEventListener("error", () => {
        if (disposed || stream !== current) return;
        onRunners([]);
        // CONNECTING retries itself. HTTP failures such as 503 leave it permanently CLOSED.
        if (current.readyState === EventSource.CLOSED) {
          current.close();
          stream = undefined;
          retryTimer = setTimeout(openStream, retryDelayMs);
          retryDelayMs = Math.min(retryDelayMs * 2, 5_000);
        }
      });
    } catch {
      dispose();
      onRunners([]);
    }
  }
  openStream();
  return dispose;
}

function parseSnapshot(text: string): InterceptionRunner[] {
  const snapshot = JSON.parse(text) as { runners?: InterceptionRunner[] } | null;
  if (
    !Array.isArray(snapshot?.runners) ||
    !snapshot.runners.every(
      (runner) =>
        runner &&
        typeof runner.id === "string" &&
        Array.isArray(runner.routes) &&
        runner.routes.every(
          (route) =>
            route && typeof route.id === "string" && typeof route.method === "string" && typeof route.path === "string"
        )
    )
  ) {
    throw new Error("Invalid override snapshot.");
  }
  return snapshot.runners;
}
