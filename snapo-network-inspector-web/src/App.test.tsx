// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AppInspectorKind,
  CdpMessage,
  InspectableApp,
  SelectedAppInspector,
  SnapOServer,
  StreamEvent
} from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { recordId } from "./network/cdp";
import type { NetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { InspectorRestoration } from "./features/app-inspector/restoration";
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
  NetworkInspectorApp: ({
    model,
    inspectorSelection
  }: {
    model: NetworkInspectorModel;
    inspectorSelection: SelectedAppInspector | null;
  }) => {
    mocks.model = model;
    return <div data-inspector="network" data-socket={inspectorSelection?.server.socketName} />;
  }
}));
vi.mock("./features/tweaks-inspector/TweaksInspectorApp", () => ({
  TweaksInspectorApp: () => <div data-inspector="tweaks" />
}));

function app(pid: number, kinds: AppInspectorKind[]): InspectableApp {
  return {
    id: `phone:pid:${pid}`,
    name: "Demo",
    packageName: "com.example.demo",
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

describe("app inspector restoration UI", () => {
  let root: Root;
  let container: HTMLDivElement;
  let discovered: InspectableApp[];
  let nativeSelect: (selection: SelectedAppInspector) => void;
  let events: Set<(event: StreamEvent) => void>;

  beforeEach(() => {
    vi.useFakeTimers();
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    discovered = [app(20, ["tweaks"])];
    events = new Set();
    mocks.model = null;
    const saved = new InspectorRestoration();
    saved.reconcile([app(10, ["network", "tweaks"])]);
    mocks.client = {
      usesNativeServerPicker: true,
      loadInspectorPreferences: vi.fn(async () => saved.serialize()),
      saveInspectorPreferences: vi.fn(async () => {}),
      listInspectorApps: vi.fn(async () => discovered),
      listServers: vi.fn(async () =>
        discovered.flatMap((app) =>
          app.inspectors
            .filter((option) => option.kind === "network")
            .map(
              (option): SnapOServer => ({
                ...option.server,
                server: app.id,
                deviceDisplayTitle: app.deviceDisplayTitle,
                displayName: app.name,
                isConnected: true,
                hasAppInfo: true,
                instanceId: app.id,
                isProtocolNewerThanSupported: false,
                isProtocolOlderThanSupported: false
              })
            )
        )
      ),
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
      selectedDeviceChanged: vi.fn(),
      onPreferredDevice: vi.fn(() => () => {}),
      nativeInspectorStateChanged: vi.fn(),
      onNativeSelectedServer: vi.fn(() => () => {}),
      onNativeSearchText: vi.fn(() => () => {}),
      onNativeSortOrder: vi.fn(() => () => {}),
      onNativeClearCompleted: vi.fn(() => () => {}),
      onNativeCopySelectedUrl: vi.fn(() => () => {}),
      onNativeCopySelectedCurl: vi.fn(() => () => {}),
      onNativeExportVisibleHar: vi.fn(() => () => {}),
      appInspectorStateChanged: vi.fn(),
      onNativeSelectedInspector: vi.fn((callback) => {
        nativeSelect = callback;
        return () => {};
      }),
      onNativeSelectedApp: vi.fn(() => () => {})
    } as unknown as NetworkClient;
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    vi.useRealTimers();
  });

  it("shows only an accessible spinner until the remembered inspector appears", async () => {
    await act(async () => root.render(<App />));
    expect(container.querySelector('[role="status"] svg')).not.toBeNull();
    expect(container.textContent).toBe("");
    expect(container.querySelector("[data-inspector]")).toBeNull();

    discovered = [app(20, ["network", "tweaks"])];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(container.querySelector('[data-inspector="network"]')?.getAttribute("data-socket")).toBe("snapo_network_20");
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it("honors a native explicit choice while discovery is in flight", async () => {
    await act(async () => root.render(<App />));
    let finish!: (apps: InspectableApp[]) => void;
    vi.mocked(mocks.client.listInspectorApps).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    await act(async () => nativeSelect({ appId: discovered[0].id, ...discovered[0].inspectors[0] }));
    expect(container.querySelector('[data-inspector="tweaks"]')).not.toBeNull();
    await act(async () => finish([app(20, ["network", "tweaks"])]));
    expect(container.querySelector('[data-inspector="tweaks"]')).not.toBeNull();
  });

  it("keeps a browser picker available during restoration", async () => {
    Object.assign(mocks.client, { usesNativeServerPicker: false });
    await act(async () => root.render(<App />));
    expect(container.querySelector('button[aria-label="Select an app"]')).not.toBeNull();
    const tweaks = container.querySelector('button[aria-label="Tweaks"]') as HTMLButtonElement;
    await act(async () => tweaks.click());
    expect(container.querySelector('[data-inspector="tweaks"]')).not.toBeNull();
  });

  async function captureTraffic() {
    discovered = [app(20, ["network", "tweaks"])];
    await act(async () => root.render(<App />));
    const server = discovered[0].inspectors[0].server;
    await act(async () => {
      for (const message of replayMessages) {
        for (const receive of events)
          receive({ streamId: "network-stream", server, serverInstanceId: discovered[0].id, message });
      }
    });
    expect(mocks.model?.allRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" });
  }

  it("retains actual records, bodies, and selection while reconnecting", async () => {
    await captureTraffic();
    const selectedRecordId = mocks.model?.selectedRecordId;
    const bodyLoads = vi.mocked(mocks.client.loadBodies).mock.calls.length;
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
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
    await act(async () => vi.advanceTimersByTimeAsync(5_000));
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);

    await act(async () => mocks.model?.setSearchText("no-match"));
    expect(mocks.model?.visibleRecords).toHaveLength(0);
    await act(async () => mocks.model?.setSearchText(""));
    expect(mocks.model?.visibleRecords).toHaveLength(1);

    discovered = [app(20, ["network", "tweaks"])];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(mocks.model?.allRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecordId).toBe(selectedRecordId);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);
  });

  it("honors cached native toolbar choices offline without starting stale streams", async () => {
    await captureTraffic();
    const initial = discovered[0];
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    const starts = vi.mocked(mocks.client.startStream).mock.calls.length;
    await act(async () => nativeSelect({ appId: initial.id, ...initial.inspectors[1] }));
    expect(container.querySelector(".inspector-loading-shell")).not.toBeNull();
    expect(mocks.client.appInspectorStateChanged).toHaveBeenLastCalledWith(
      expect.objectContaining({ selection: null, preferredKind: "tweaks", isRestoring: true })
    );
    await act(async () => nativeSelect({ appId: initial.id, ...initial.inspectors[0] }));
    expect(container.querySelector('[data-inspector="network"]')).not.toBeNull();
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
    expect(mocks.client.startStream).toHaveBeenCalledTimes(starts);
  });

  it("retains old-process traffic when a new PID has nothing to replay", async () => {
    await captureTraffic();
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    discovered = [app(30, ["network", "tweaks"])];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(mocks.model?.selectedServer?.socketName).toBe("snapo_network_30");
    expect(mocks.model?.visibleRecords).toHaveLength(0);
    expect(mocks.model?.allRecords).toMatchObject([
      { server: { socketName: "snapo_network_20" }, responseBody: "cached response" }
    ]);
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
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    await act(async () => mocks.model!.selectRecord(recordId(second)));
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-2" });
    expect(mocks.client.loadBodies).toHaveBeenCalledTimes(bodyLoads);
    await act(async () => mocks.model!.selectRecord(firstId));
    expect(mocks.model?.selectedRecord).toMatchObject({ requestId: "request-1", responseBody: "cached response" });
  });

  it("retains network traffic while viewing Tweaks", async () => {
    await captureTraffic();
    await act(async () => nativeSelect({ appId: discovered[0].id, ...discovered[0].inspectors[1] }));
    expect(container.querySelector('[data-inspector="tweaks"]')).not.toBeNull();
    expect(mocks.client.stopStream).toHaveBeenCalled();
    await act(async () => nativeSelect({ appId: discovered[0].id, ...discovered[0].inspectors[0] }));
    expect(mocks.model?.allRecords).toHaveLength(1);
    expect(mocks.model?.selectedRecord).toMatchObject({ responseBody: "cached response" });
  });
});
