import type { Host } from "@snap-o/tool-host";

export interface SampleItem {
  id: string;
  name: string;
  value: string | number | boolean;
}

export interface ExampleState {
  connected: boolean;
  items: SampleItem[];
  message: string;
}

type ConnectionHost = Pick<Host, "connection" | "onConnection">;

/** Stops this page's requests and stream while inactive. The native host owns process/tool isolation. */
export function observeExample(
  host: ConnectionHost,
  changed: (state: ExampleState) => void,
) {
  let request: AbortController | undefined;
  let command: AbortController | undefined;
  let events: EventSource | undefined;
  let stopped = false;
  let revision = -1;
  let items: SampleItem[] = [];

  function available() {
    return !stopped && host.connection?.protocolVersion === 1;
  }

  function accept(payload: unknown) {
    const snapshot = readSnapshot(payload);
    // An older GET response can arrive after a newer SSE snapshot.
    if (snapshot.revision < revision) return;
    revision = snapshot.revision;
    items = snapshot.items;
    changed({ connected: true, items, message: "Live · all values are fake" });
  }

  function failed(error: unknown) {
    changed({
      connected: true,
      items,
      message:
        error instanceof Error ? error.message : "Example request failed.",
    });
  }

  async function fetchSnapshot(
    path: string,
    method: string,
    controller: AbortController,
  ) {
    const connection = host.connection;
    if (!connection) return;
    const response = await fetch(new URL(path, connection.baseURL), {
      method,
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]),
      cache: "no-store",
      redirect: "error",
    });
    if (!response.ok)
      throw new Error(`Example request failed (${response.status}).`);
    const payload: unknown = await response.json();
    if (!controller.signal.aborted) accept(payload);
  }

  async function refresh() {
    request?.abort();
    if (!available()) return;
    const current = new AbortController();
    request = current;
    try {
      await fetchSnapshot("example", "GET", current);
    } catch (error) {
      if (!current.signal.aborted) failed(error);
    }
  }

  async function increment() {
    if (!available() || command) return;
    const current = new AbortController();
    command = current;
    try {
      await fetchSnapshot("example/increment", "POST", current);
    } catch (error) {
      if (!current.signal.aborted) throw error;
    } finally {
      if (command === current) command = undefined;
    }
  }

  function disconnect() {
    request?.abort();
    command?.abort();
    command = undefined;
    events?.close();
    events = undefined;
  }

  function connectionChanged() {
    disconnect();
    revision = -1;
    items = [];
    const connection = host.connection;
    const connected = connection !== null;
    changed({
      connected,
      items,
      message: connected ? "Loading fake data…" : "Disconnected",
    });
    if (!connection) return;
    if (connection.protocolVersion !== 1) {
      failed(new Error("This Example frontend requires protocol 1."));
      return;
    }
    if (!available()) return;
    void refresh();
    const stream = new EventSource(
      new URL("example/events", connection.baseURL),
    );
    events = stream;
    stream.addEventListener("snapshot", (event) => {
      if (events !== stream) return;
      try {
        accept(JSON.parse((event as MessageEvent<string>).data));
      } catch (error) {
        failed(error);
      }
    });
    stream.onerror = () => {
      if (events === stream) failed(new Error("Reconnecting to fake events…"));
    };
  }

  const unsubscribe = host.onConnection(connectionChanged);
  return {
    refresh,
    increment,
    dispose() {
      stopped = true;
      disconnect();
      unsubscribe();
    },
  };
}

function readSnapshot(payload: unknown): {
  revision: number;
  items: SampleItem[];
} {
  if (
    typeof payload !== "object" ||
    payload === null ||
    !("protocolVersion" in payload) ||
    payload.protocolVersion !== 1 ||
    !("revision" in payload) ||
    typeof payload.revision !== "number" ||
    !Number.isSafeInteger(payload.revision) ||
    payload.revision < 0 ||
    !("items" in payload) ||
    !Array.isArray(payload.items)
  ) {
    throw new Error("Unsupported Example snapshot.");
  }
  for (const item of payload.items) {
    if (
      typeof item !== "object" ||
      item === null ||
      typeof item.id !== "string" ||
      typeof item.name !== "string" ||
      !["string", "number", "boolean"].includes(typeof item.value)
    ) {
      throw new Error("Invalid Example item.");
    }
  }
  return { revision: payload.revision, items: payload.items };
}
