// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AppInspectorKind,
  CdpMessage,
  InspectableApp,
  InspectorHostState,
  StreamEvent
} from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { recordId } from "./network/cdp";
import type { NetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { App } from "./App";

const mocks = vi.hoisted(() => ({
  client: null as unknown as NetworkClient,
  model: null as NetworkInspectorModel | null
}));
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
    params: {
      requestId: "request-1",
      timestamp: 100.25,
      encodedDataLength: 12
    }
  }
];
vi.mock("./network/client", () => ({ createNetworkClient: () => mocks.client }));
vi.mock("./features/network-inspector/NetworkInspectorApp", () => ({
  NetworkInspectorApp: ({ model }: { model: NetworkInspectorModel }) => {
    mocks.model = model;
    return <div data-inspector="network" data-socket={model.selectedServer?.socketName} />;
  }
}));

function app(pid: number, kinds: AppInspectorKind[]): InspectableApp {
  return {
    id: `phone:pid:${pid}`,
    name: "Demo",
    packageName: "com.example.demo",
    androidUserId: 0,
    processName: "com.example.demo",
    deviceId: "phone",
    deviceDisplayTitle: "Phone",
    inspectors: kinds.map((kind) => ({
      kind,
      protocolVersion: 4,
      server: { deviceId: "phone", socketName: `snapo_${kind}_${pid}` }
    }))
  };
}

describe("native Network selection", () => {
  let container: HTMLDivElement;
  let discovered: InspectableApp[];
  let host: InspectorHostState;
  let receiveHost: (state: InspectorHostState) => void;
  let nativeSearch: (text: string) => void;
  let events: Set<(event: StreamEvent) => void>;

  beforeEach(() => {
    vi.useFakeTimers();
    discovered = [app(20, ["network", "tweaks"])];
    host = connected(discovered[0]);
    events = new Set();
    mocks.model = null;
    mocks.client = {
      inspectorHostState: vi.fn(async () => structuredClone(host)),
      onInspectorHostState: vi.fn((callback) => {
        receiveHost = callback;
        return () => {};
      }),
      openSelectedApp: vi.fn(async () => {}),
      startStream: vi.fn(async () => ({ streamId: "network-stream" })),
      stopStream: vi.fn(async () => {}),
      loadBodies: vi.fn(async ({ requestId }) => ({ requestId, responseBody: "cached response" })),
      onEvent: vi.fn((callback) => {
        events.add(callback);
        return () => events.delete(callback);
      }),
      onStatus: vi.fn(() => () => {}),
      debugInspectorPreset: vi.fn(async () => "live"),
      onDebugInspectorPreset: vi.fn(() => () => {}),
      nativeInspectorStateChanged: vi.fn(),
      onNativeSearchText: vi.fn((callback) => {
        nativeSearch = callback;
        return () => {};
      }),
      listExclusionFilters: vi.fn(async () => []),
      onNativeExclusionFilters: vi.fn(() => () => {}),
      onNativeSortOrder: vi.fn(() => () => {}),
      onNativeClearCompleted: vi.fn(() => () => {}),
      onNativeCopySelectedUrl: vi.fn(() => () => {}),
      onNativeCopySelectedCurl: vi.fn(() => () => {}),
      onNativeExportVisibleHar: vi.fn(() => () => {})
    } as unknown as NetworkClient;
    container = document.createElement("div");
    document.body.append(container);
  });

  afterEach(async () => {
    await act(async () => {
      await render(null, container);
    });
    container.remove();
    vi.useRealTimers();
  });

  function connected(target: InspectableApp): InspectorHostState {
    const selection = { appId: target.id, ...target.inspectors[0] };
    return {
      revision: 0,
      selection,
      selectedApp: target,
      isActive: true,
      isConnected: true,
      isWaiting: false,
      networkServer: {
        ...selection.server,
        server: target.id,
        deviceDisplayTitle: target.deviceDisplayTitle,
        displayName: target.name,
        isConnected: true,
        hasAppInfo: true,
        instanceId: target.id,
        isProtocolNewerThanSupported: false,
        isProtocolOlderThanSupported: false
      },
      appLaunch: { pending: false }
    };
  }

  async function publish(state: Partial<InspectorHostState>, launch = host.appLaunch) {
    host = { ...host, ...state, revision: host.revision + 1, appLaunch: launch };
    await act(async () => receiveHost(structuredClone(host)));
  }

  async function disconnect() {
    discovered = [];
    await publish({
      isConnected: false,
      isWaiting: true,
      networkServer: { ...host.networkServer!, isConnected: false }
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_500);
    });
  }

  async function captureTraffic() {
    discovered = [app(20, ["network", "tweaks"])];
    await act(async () => render(<App />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const server = discovered[0].inspectors[0].server;
    await act(async () => {
      for (const message of replayMessages) {
        for (const receive of events)
          receive({ streamId: "network-stream", server, serverInstanceId: discovered[0].id, message });
      }
    });
    expect(mocks.model?.allRecords).toHaveLength(1);
    await vi.waitFor(() => {
      expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" });
    });
  }

  it("retains actual records, bodies, and selection while reconnecting", async () => {
    await captureTraffic();
    const selectedRecordId = mocks.model?.selectedRecordId;
    const bodyLoads = vi.mocked(mocks.client.loadBodies).mock.calls.length;
    await disconnect();
    expect(container.querySelector(".inspector-loading-shell")).toBeNull();
    expect(container.querySelector('[data-inspector="network"]')).not.toBeNull();
    expect(mocks.model?.selectedServer?.isConnected).toBe(false);
    expect(mocks.model?.visibleRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.nativeInspectorStateChanged).toHaveBeenLastCalledWith(
      expect.objectContaining({
        selectedServer: { deviceId: "phone", socketName: "snapo_network_20" },
        hasVisibleRecords: true
      })
    );
    expect(mocks.client.stopStream).toHaveBeenCalled();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);

    await act(async () => nativeSearch("no-match"));
    expect(mocks.model?.visibleRecords).toHaveLength(0);
    await act(async () => nativeSearch(""));
    expect(mocks.model?.visibleRecords).toHaveLength(1);

    discovered = [app(20, ["network", "tweaks"])];
    await publish(connected(discovered[0]));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_500);
    });
    expect(mocks.model?.allRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecordId).toBe(selectedRecordId);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);
  });

  it("allows browsing another captured request without loading bodies offline", async () => {
    await captureTraffic();
    const server = discovered[0].inspectors[0].server;
    await act(async () => {
      for (const original of replayMessages) {
        const message = {
          ...original,
          snapoSequence: (original.snapoSequence ?? 0) + 10,
          params: { ...original.params, requestId: "request-2" }
        };
        for (const receive of events)
          receive({ streamId: "network-stream", server, serverInstanceId: discovered[0].id, message });
      }
    });
    const firstId = mocks.model!.selectedRecordId!;
    const second = mocks.model!.allRecords.find(
      (record) => record.kind === "request" && record.requestId === "request-2"
    )!;
    const bodyLoads = vi.mocked(mocks.client.loadBodies).mock.calls.length;
    await disconnect();
    await act(async () => {
      await mocks.model!.selectRecord(recordId(second));
    });
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-2" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);
    await act(async () => {
      await mocks.model!.selectRecord(firstId);
    });
    await vi.waitFor(() => {
      expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" });
    });
  });

  it("keeps Network data while its page is hidden for Tweaks", async () => {
    await captureTraffic();
    const initial = host;
    await publish({ selection: null, networkServer: null, isActive: false, isConnected: false });
    expect(mocks.client.stopStream).toHaveBeenCalled();
    await publish(initial);
    expect(mocks.model?.allRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
  });

  it("waits for the host to authorize a replacement process", async () => {
    await captureTraffic();
    await disconnect();
    discovered = [app(30, ["network", "tweaks"])];
    await publish({});
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_500);
    });
    expect(mocks.model?.selectedServer?.socketName).toBe("snapo_network_20");
    expect(mocks.client.startStream).not.toHaveBeenCalledWith(discovered[0].inspectors[0].server);
    await publish(connected(discovered[0]));
    expect(mocks.model?.selectedServer?.socketName).toBe("snapo_network_30");
    expect(mocks.model?.visibleRecords).toHaveLength(0);
    expect(mocks.model?.allRecords).toMatchObject([
      { server: { socketName: "snapo_network_20" }, responseBody: "cached response" }
    ]);
  });

  it("uses pushed metadata without polling or restarting an unchanged connection", async () => {
    await captureTraffic();
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    await publish({});
    await publish({ networkServer: { ...host.networkServer!, displayName: "Updated name" } });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.model?.selectedServer?.displayName).toBe("Updated name");
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(mocks.client.inspectorHostState).toHaveBeenCalledTimes(1);
    expect(mocks.client.stopStream).not.toHaveBeenCalled();
    await publish({ networkServer: { ...host.networkServer!, instanceId: "new-session" } });
    expect(mocks.client.stopStream).toHaveBeenCalledTimes(1);
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts + 1);
  });

  it("ignores an initial state reply that arrives after a newer host event", async () => {
    let reply!: (state: InspectorHostState) => void;
    vi.mocked(mocks.client.inspectorHostState).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          reply = resolve;
        })
    );
    const old = structuredClone(host);
    await act(async () => render(<App />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await publish({ selection: null, networkServer: null, isConnected: false, isWaiting: true });
    await act(async () => reply(old));
    expect(container.querySelector(".inspector-loading-shell")).not.toBeNull();
    expect(mocks.client.startStream).not.toHaveBeenCalled();
  });

  it("shows native launch status and sends only the Open command", async () => {
    host = { ...host, selection: null, networkServer: null, isConnected: false, isWaiting: true };
    await act(async () => render(<App />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await act(async () => container.querySelector<HTMLButtonElement>(".inspector-open-app")!.click());
    expect(mocks.client.openSelectedApp).toHaveBeenCalledWith(host.selectedApp!.id);
    await publish({}, { pending: true });
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    await publish({}, { pending: false, error: "Device is offline." });
    expect(container.textContent).toContain("Device is offline.");
    expect(container.querySelector(".inspector-open-app")).not.toBeNull();
  });
});
