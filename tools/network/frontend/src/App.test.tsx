// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CdpMessage, StreamEvent } from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { recordId } from "./network/cdp";
import type { NetworkToolModel } from "./features/network-tool/hooks/useNetworkToolModel";
import { ToolHost, type Host, type ProcessManifest, type ToolDescriptor } from "@snap-o/tool-host";
import { App } from "./App";

const mocks = vi.hoisted(() => ({
  client: null as unknown as NetworkClient,
  host: null as unknown as Host,
  model: null as NetworkToolModel | null
}));
vi.mock("@snap-o/tool-host", async (original) => ({
  ...(await original<typeof import("@snap-o/tool-host")>()),
  get host() {
    return mocks.host;
  }
}));
vi.mock("./network/client", () => ({ createNetworkClient: () => mocks.client }));
vi.mock("./features/network-tool/NetworkToolApp", () => ({
  NetworkToolApp: ({ model }: { model: NetworkToolModel }) => {
    mocks.model = model;
    return <div data-tool="network" />;
  }
}));
const metadata = {
  name: "Demo",
  packageName: "com.example.demo",
  pid: 20,
  protocolVersion: 3,
  processIdentity: "boot:20:123"
};
const replayMessages: CdpMessage[] = [
  {
    method: "Network.requestWillBeSent",
    snapoSequence: 1,
    params: {
      requestId: "request-1",
      wallTime: 1_710_000_000,
      timestamp: 100,
      request: { url: "https://example.test/items", method: "GET", headers: {}, hasPostData: false }
    }
  },
  {
    method: "Network.responseReceived",
    snapoSequence: 2,
    params: {
      requestId: "request-1",
      timestamp: 100.1,
      type: "XHR",
      response: { url: "https://example.test/items", status: 200, headers: {}, mimeType: "application/json" }
    }
  },
  {
    method: "Network.loadingFinished",
    snapoSequence: 3,
    params: { requestId: "request-1", timestamp: 100.25, encodedDataLength: 12 }
  }
];

describe("Network frontend with the shared host", () => {
  let container: HTMLDivElement;
  let state: {
    revision: number;
    connected: boolean;
    baseURL?: string;
    manifest?: ProcessManifest;
    inspector?: ToolDescriptor;
  };
  let listeners: Map<string, (value: unknown) => void>;
  let requests: ReturnType<typeof vi.fn<(command: string, payload?: unknown) => Promise<unknown>>>;
  let events: Set<(event: StreamEvent) => void>;
  let fetchMetadata: ReturnType<typeof vi.fn<typeof fetch>>;

  beforeEach(() => {
    vi.useFakeTimers();
    state = {
      revision: 1,
      connected: true,
      baseURL: "http://127.0.0.1:1234/",
      manifest: {
        version: 1,
        pid: metadata.pid,
        processIdentity: metadata.processIdentity,
        app: { name: metadata.name, packageName: metadata.packageName, revision: "1", inspectors: [] }
      },
      inspector: { id: "network", name: "Network", protocolVersion: 3 }
    };
    listeners = new Map();
    requests = vi.fn(async (command) => (command === "hostState" ? { ...state } : undefined));
    mocks.host = new ToolHost({
      request: async <T,>(command: string, payload?: unknown) => (await requests(command, payload)) as T,
      listen: <T,>(name: string, callback: (value: T) => void) => {
        listeners.set(name, callback as (value: unknown) => void);
        return () => listeners.delete(name);
      }
    });
    fetchMetadata = vi.fn<typeof fetch>(async () => Response.json(metadata));
    vi.stubGlobal("fetch", fetchMetadata);
    events = new Set();
    mocks.model = null;
    mocks.client = {
      appVersion: vi.fn(async () => "1.0"),
      startStream: vi.fn(async () => ({ streamId: "network-stream" })),
      stopStream: vi.fn(async () => {}),
      loadBodies: vi.fn(async ({ requestId }) => ({ requestId, responseBody: "cached response" })),
      onEvent: vi.fn((callback) => {
        events.add(callback);
        return () => events.delete(callback);
      }),
      onStatus: vi.fn(() => () => {}),
      listExclusionFilters: vi.fn(async () => []),
      addExclusionFilter: vi.fn(async () => {}),
      removeExclusionFilter: vi.fn(async () => {}),
      copyText: vi.fn(async () => {}),
      openExternal: vi.fn(async () => {}),
      saveFile: vi.fn(async () => ({ saved: false })),
      dispose: vi.fn()
    };
    container = document.createElement("div");
    document.body.append(container);
  });

  afterEach(async () => {
    await act(async () => render(null, container));
    container.remove();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function flush() {
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
  }
  async function publish(connected: boolean) {
    state = { ...state, revision: state.revision + 1, connected };
    await act(async () => listeners.get("host:connection")?.({ ...state }));
    await flush();
  }
  function toolbar() {
    return requests.mock.calls.filter(([name]) => name === "setToolbar").at(-1)![1] as {
      revision: number;
      actions: { id: string; type: string; enabled: boolean; inputRevision?: number }[];
    };
  }
  async function search(value: string, inputRevision: number) {
    const current = toolbar();
    await act(async () =>
      listeners.get("host:toolbar")?.({
        revision: current.revision,
        id: current.actions.find((item) => item.type === "search")!.id,
        value,
        inputRevision
      })
    );
  }
  async function captureTraffic() {
    await act(async () => render(<App />, container));
    await flush();
    await act(async () => {
      for (const message of replayMessages)
        for (const receive of events) {
          receive({ streamId: "network-stream", processId: "boot:20:123", message });
        }
    });
    expect(mocks.model?.allRecords).toHaveLength(1);
    await vi.waitFor(() =>
      expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" })
    );
  }

  it("retains records, bodies, selection, and working search while reconnecting", async () => {
    await captureTraffic();
    const selected = mocks.model!.selectedRecordId;
    const loads = vi.mocked(mocks.client.loadBodies).mock.calls.length;
    await publish(false);
    expect(mocks.model?.isConnected).toBe(false);
    expect(mocks.model?.visibleRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.stopStream).toHaveBeenCalled();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(loads);
    await search("no-match", 1);
    expect(mocks.model?.visibleRecords).toHaveLength(0);
    await search("", 2);
    expect(mocks.model?.visibleRecords).toHaveLength(1);
    await publish(true);
    expect(mocks.model?.selectedRecordId).toBe(selected);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(loads);
  });

  it("allows browsing another captured request without loading bodies offline", async () => {
    await captureTraffic();
    await act(async () => {
      for (const original of replayMessages)
        for (const receive of events)
          receive({
            streamId: "network-stream",
            processId: "boot:20:123",
            message: {
              ...original,
              snapoSequence: original.snapoSequence! + 10,
              params: { ...original.params, requestId: "request-2" }
            }
          });
    });
    const first = mocks.model!.selectedRecordId!;
    const second = mocks.model!.allRecords.find(
      (record) => record.kind === "request" && record.requestId === "request-2"
    )!;
    const loads = vi.mocked(mocks.client.loadBodies).mock.calls.length;
    await publish(false);
    await act(async () => mocks.model!.selectRecord(recordId(second)));
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-2" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(loads);
    await act(async () => mocks.model!.selectRecord(first));
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" });
  });

  it("does not fetch or start a stream until the host connects", async () => {
    state.connected = false;
    await act(async () => render(<App />, container));
    await flush();
    expect(fetchMetadata).not.toHaveBeenCalled();
    expect(mocks.client.startStream).not.toHaveBeenCalled();
    await publish(true);
    expect(fetchMetadata).not.toHaveBeenCalled();
    expect(mocks.client.startStream).toHaveBeenCalledWith(metadata);
  });

  it("does not restart an unchanged connection after a repeated host update", async () => {
    await captureTraffic();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    const metadataReads = fetchMetadata.mock.calls.length;
    await act(async () => {
      listeners.get("host:connection")?.({ ...state });
      listeners.get("host:connection")?.({ ...state });
    });
    await flush();
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(fetchMetadata).toHaveBeenCalledTimes(metadataReads);
    await publish(true);
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts + 1);
  });

  it("refreshes after a disconnect and reconnect delivered in one render", async () => {
    await captureTraffic();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    await act(async () => {
      listeners.get("host:connection")?.({ ...state, revision: ++state.revision, connected: false });
      listeners.get("host:connection")?.({ ...state, revision: ++state.revision, connected: true });
    });
    await flush();
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts + 1);
    expect(mocks.model?.allRecords).toHaveLength(1);
  });

  it("waits for manifest metadata before starting a connected tool", async () => {
    const manifest = state.manifest;
    state.manifest = undefined;
    await act(async () => render(<App />, container));
    await flush();
    expect(mocks.client.startStream).not.toHaveBeenCalled();
    state.manifest = manifest;
    await publish(true);
    expect(mocks.client.startStream).toHaveBeenCalledWith(metadata);
    expect(fetchMetadata).not.toHaveBeenCalled();
  });

  it("uses host metadata with the real Network connection on each reconnect", async () => {
    const { createNetworkClient } = await vi.importActual<typeof import("./network/client")>("./network/client");
    class Events extends EventTarget {
      constructor() {
        super();
        queueMicrotask(() => this.dispatchEvent(new Event("open")));
      }
      close() {}
    }
    vi.stubGlobal("EventSource", Events);
    fetchMetadata.mockImplementation(async (url) => {
      if (String(url).endsWith("/network"))
        return new Response("", {
          headers: { "Content-Type": "application/x-ndjson", "SnapO-Sequence": "0" }
        });
      throw new Error(`Unexpected request: ${url}`);
    });
    mocks.client = createNetworkClient();
    await act(async () => render(<App />, container));
    await flush();
    await vi.waitFor(() =>
      expect(fetchMetadata.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual(["/network"])
    );
    await publish(false);
    await publish(true);
    await vi.waitFor(() =>
      expect(fetchMetadata.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual(["/network", "/network"])
    );
  });

  it.each([0, 2, 4])("does not start a Network stream for unsupported protocol v%s", async (protocolVersion) => {
    state.inspector = { ...state.inspector!, protocolVersion };
    await act(async () => render(<App />, container));
    await flush();
    await vi.waitFor(() => expect(mocks.model?.metadata?.protocolVersion).toBe(protocolVersion));
    expect(mocks.client.startStream).not.toHaveBeenCalled();
  });

  it("updates filters after another window writes local storage", async () => {
    await captureTraffic();
    vi.mocked(mocks.client.listExclusionFilters).mockResolvedValue(["-example.test"]);
    await act(async () => {
      window.dispatchEvent(new StorageEvent("storage", { key: "network.exclusionFilters" }));
    });
    expect(mocks.model?.exclusionFilters).toEqual(["-example.test"]);
  });
});
