// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { InspectableApp, InspectorHostState, TweakList } from "./network/bridge-types";
import type { TweaksClient } from "./features/tweaks-inspector/client";
import { TweaksApp } from "./TweaksApp";

const mocks = vi.hoisted(() => ({ client: null as unknown as TweaksClient }));
vi.mock("./features/tweaks-inspector/client", () => ({ createTweaksClient: () => mocks.client }));

function app(pid: number): InspectableApp {
  return {
    id: `phone:pid:${pid}`,
    name: "Demo",
    packageName: "com.example.demo",
    androidUserId: 0,
    processName: "com.example.demo",
    deviceId: "phone",
    deviceDisplayTitle: "Phone",
    inspectors: [
      { kind: "tweaks", protocolVersion: 4, server: { deviceId: "phone", socketName: `snapo_tweaks_${pid}` } }
    ]
  };
}

function connected(target: InspectableApp): InspectorHostState {
  const selection = { appId: target.id, ...target.inspectors[0] };
  return {
    revision: 0,
    selection,
    selectedApp: target,
    networkServer: null,
    isActive: true,
    isConnected: true,
    isWaiting: false
  };
}

const list = (value: string): TweakList => ({
  tweaks: [{ name: "Demo title", type: "string", value, default: "Default" }]
});

describe("Tweaks frontend host state", () => {
  let container: HTMLDivElement;
  let host: InspectorHostState;
  let receiveHost: (state: InspectorHostState) => void;

  beforeEach(() => {
    vi.useFakeTimers();
    host = { ...connected(app(10)), appLaunch: { pending: false } };
    mocks.client = {
      inspectorHostState: vi.fn(async () => structuredClone(host)),
      onInspectorHostState: vi.fn((callback) => {
        receiveHost = callback;
        return () => {};
      }),
      openSelectedApp: vi.fn(async () => {}),
      listTweaks: vi.fn(async () => list("Cached value")),
      startTweakStream: vi.fn(async () => ({ streamId: "stream" })),
      stopTweakStream: vi.fn(async () => {}),
      onTweaksChanged: vi.fn(() => () => {}),
      onNativeTweaksReset: vi.fn(() => () => {}),
      nativeTweaksStateChanged: vi.fn()
    } as unknown as TweaksClient;
    container = document.createElement("div");
    document.body.append(container);
  });

  afterEach(async () => {
    await act(async () => render(null, container));
    container.remove();
    vi.useRealTimers();
  });

  async function publish(state: Partial<InspectorHostState>, launch = host.appLaunch) {
    host = { ...host, ...state, revision: host.revision + 1, appLaunch: launch };
    await act(async () => receiveHost(structuredClone(host)));
  }

  it("preserves values until the host connects a replacement process", async () => {
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await vi.waitFor(() =>
      expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Cached value")
    );
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    expect(input.value).toBe("Cached value");
    await publish({ isConnected: false, isWaiting: true });
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();
    await publish({});
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    vi.mocked(mocks.client.listTweaks).mockResolvedValueOnce(list("Fresh value"));
    await publish(connected(app(20)));
    expect(input.value).toBe("Fresh value");
    await vi.waitFor(() => expect(container.querySelector("fieldset")?.disabled).toBe(false));
  });

  it("retains values while hidden and waits for a fresh snapshot when shown", async () => {
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await vi.waitFor(() =>
      expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Cached value")
    );
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    await publish({ isActive: false, isConnected: false });
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(mocks.client.stopTweakStream).toHaveBeenCalledTimes(1);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    let reply!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          reply = resolve;
        })
    );
    await publish({ isActive: true, isConnected: true });
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => reply(list("Refreshed value")));
    expect(input.value).toBe("Refreshed value");
    await vi.waitFor(() => expect(container.querySelector("fieldset")?.disabled).toBe(false));
  });

  it("waits for host readiness before requesting Tweaks", async () => {
    host = { ...host, isConnected: false, isWaiting: true, selection: { ...host.selection!, protocolVersion: null } };
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(mocks.client.startTweakStream).not.toHaveBeenCalled();
    await publish(connected(app(10)));
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    expect(mocks.client.startTweakStream).toHaveBeenCalledTimes(1);
  });

  it("does not restart requests and streams when a scan repeats the same connection", async () => {
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await publish({});
    await publish({});
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    expect(mocks.client.startTweakStream).toHaveBeenCalledTimes(1);
    expect(mocks.client.stopTweakStream).not.toHaveBeenCalled();
  });

  it("shows native launch progress while waiting for the first snapshot", async () => {
    host = { ...host, selection: null, isConnected: false, isWaiting: true };
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await act(async () => container.querySelector<HTMLButtonElement>(".inspector-open-app")!.click());
    expect(mocks.client.openSelectedApp).toHaveBeenCalledWith(host.selectedApp!.id);
    await publish({}, { pending: true });
    let finish!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await publish(connected(app(20)));
    expect(container.querySelector(".tweaks-inspector")).not.toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    await publish({}, { pending: false });
    expect(container.querySelector(".inspector-open-app")?.textContent).toBe("Open Demo");
    await act(async () => finish(list("Ready")));
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Ready");
    expect(container.querySelector(".inspector-open-app")).toBeNull();
  });

  it("keeps an empty snapshot visible through disconnect", async () => {
    vi.mocked(mocks.client.listTweaks).mockResolvedValue({ tweaks: [] });
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await publish({ isConnected: false, isWaiting: true });
    expect(container.textContent).toContain("No tweaks on screen");
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it.each([
    { processName: "com.example.other", androidUserId: 0 },
    { processName: "com.example.demo", androidUserId: 10 }
  ])("clears cached values when the host selects another app or profile", async (identity) => {
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    let finish!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await publish(connected({ ...app(20), ...identity }));
    expect(container.querySelector('input[type="text"]')).toBeNull();
    await act(async () => finish({ tweaks: [] }));
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("handles absent optional fields in a native snapshot", async () => {
    await act(async () => render(<TweaksApp />, container));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await act(async () =>
      receiveHost({
        revision: 1,
        isActive: true,
        isConnected: false,
        isWaiting: true
      } as InspectorHostState)
    );
    expect(container.querySelector('input[type="text"]')).toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
  });
});
