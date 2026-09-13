// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CdpMessage, StreamEvent } from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { recordId } from "./network/cdp";
import type { NetworkToolModel } from "./features/network-tool/hooks/useNetworkToolModel";
import { ToolHost, type Host } from "@snap-o/tool-host";
type ToolDescriptor = { id: string; name: string };
type ProcessManifest = {
  version: number;
  pid: number;
  processIdentity: string;
  app: { name: string; packageName: string; revision: string; inspectors: ToolDescriptor[] };
};
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
  let fetchRequest: ReturnType<typeof vi.fn<typeof fetch>>;

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
      inspector: { id: "network", name: "Network" }
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
    fetchRequest = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchRequest);
    events = new Set();
    mocks.model = null;
    mocks.client = {
      startStream: vi.fn(async () => ({ streamId: "network-stream" })),
      stopStream: vi.fn(async () => {}),
      loadBodies: vi.fn(async ({ requestId }) => ({ requestId, responseBody: "cached response" })),
      onEvent: vi.fn((callback) => {
        events.add(callback);
        return () => events.delete(callback);
      }),
      onClosed: vi.fn(() => () => {}),
      listExclusionFilters: vi.fn(() => []),
      addExclusionFilter: vi.fn(() => {}),
      removeExclusionFilter: vi.fn(() => {}),
      copyText: vi.fn(async () => {}),
      saveFile: vi.fn(async () => false),
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
    expect(fetchRequest).not.toHaveBeenCalled();
    expect(mocks.client.startStream).not.toHaveBeenCalled();
    await publish(true);
    expect(fetchRequest).not.toHaveBeenCalled();
    expect(mocks.client.startStream).toHaveBeenCalledWith(
      expect.objectContaining({ processIdentity: metadata.processIdentity })
    );
  });

  it("does not restart an unchanged connection after a repeated host update", async () => {
    await captureTraffic();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    const metadataReads = fetchRequest.mock.calls.length;
    await act(async () => {
      listeners.get("host:connection")?.({ ...state });
      listeners.get("host:connection")?.({ ...state });
    });
    await flush();
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(fetchRequest).toHaveBeenCalledTimes(metadataReads);
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
    expect(mocks.client.startStream).toHaveBeenCalledWith(
      expect.objectContaining({ processIdentity: metadata.processIdentity })
    );
    expect(fetchRequest).not.toHaveBeenCalled();
  });

  it("uses host metadata with the real Network connection on each reconnect", async () => {
    const { createNetworkClient } = await vi.importActual<typeof import("./network/client")>("./network/client");
    const streams: Events[] = [];
    class Events extends EventTarget {
      constructor() {
        super();
        streams.push(this);
        queueMicrotask(() => this.dispatchEvent(new Event("open")));
      }
      close = vi.fn();
    }
    vi.stubGlobal("EventSource", Events);
    fetchRequest.mockImplementation(async (url) => {
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
      expect(fetchRequest.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual(["/network"])
    );
    await publish(false);
    expect(streams[0].close).toHaveBeenCalledOnce();
    await publish(true);
    await vi.waitFor(() =>
      expect(fetchRequest.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual(["/network", "/network"])
    );
    await act(async () => render(null, container));
    expect(streams[1].close).toHaveBeenCalledOnce();
  });

  it("updates filters after successful writes and preserves them when writes fail", async () => {
    let stored = ["-initial.test"];
    vi.mocked(mocks.client.listExclusionFilters).mockImplementation(() => stored);
    vi.mocked(mocks.client.addExclusionFilter).mockImplementation((filter) => {
      stored = [...stored, filter];
    });
    vi.mocked(mocks.client.removeExclusionFilter).mockImplementation((filter) => {
      stored = stored.filter((item) => item !== filter);
    });
    await captureTraffic();
    await act(() => mocks.model!.addExclusionFilter("NEW.test"));
    expect(mocks.model?.exclusionFilters).toEqual(["-initial.test", "-new.test"]);
    await act(() => mocks.model!.removeExclusionFilter("-initial.test"));
    expect(mocks.model?.exclusionFilters).toEqual(["-new.test"]);
    vi.mocked(mocks.client.addExclusionFilter).mockImplementation(() => {
      throw new Error("Storage full");
    });
    vi.mocked(mocks.client.removeExclusionFilter).mockImplementation(() => {
      throw new Error("Storage full");
    });
    await act(() => mocks.model!.addExclusionFilter("failed.test"));
    await act(() => mocks.model!.removeExclusionFilter("-new.test"));
    expect(mocks.model?.exclusionFilters).toEqual(["-new.test"]);
  });

  it("updates filters after another window writes local storage", async () => {
    await captureTraffic();
    vi.mocked(mocks.client.listExclusionFilters).mockReturnValue(["-example.test"]);
    await act(async () => {
      window.dispatchEvent(new StorageEvent("storage", { key: "network.exclusionFilters" }));
    });
    expect(mocks.model?.exclusionFilters).toEqual(["-example.test"]);
  });
});
