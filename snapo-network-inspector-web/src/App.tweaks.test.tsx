// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AppInspectorKind, InspectableApp, TweakList } from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { InspectorRestoration } from "./features/app-inspector/restoration";
import { App } from "./App";

const mocks = vi.hoisted(() => ({ client: null as unknown as NetworkClient }));
vi.mock("./network/client", () => ({ createNetworkClient: () => mocks.client }));
vi.mock("./features/network-inspector/hooks/useNetworkInspectorModel", () => ({
  useNetworkInspectorModel: () => ({})
}));
vi.mock("./features/network-inspector/NetworkInspectorApp", () => ({ NetworkInspectorApp: () => null }));

function app(pid: number, kind: AppInspectorKind = "tweaks"): InspectableApp {
  return {
    id: `phone:pid:${pid}`,
    name: "Demo",
    packageName: "com.example.demo",
    androidUserId: 0,
    processName: "com.example.demo",
    deviceId: "phone",
    deviceDisplayTitle: "Phone",
    inspectors: [{ kind, protocolVersion: 4, server: { deviceId: "phone", socketName: `snapo_${kind}_${pid}` } }]
  };
}

describe("retained Tweaks view", () => {
  let root: Root;
  let container: HTMLDivElement;
  let discovered: InspectableApp[];
  let selectApp: (id: string) => void;

  beforeEach(() => {
    vi.useFakeTimers();
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    discovered = [app(10)];
    const saved = new InspectorRestoration();
    saved.reconcile(discovered);
    mocks.client = {
      usesNativeServerPicker: true,
      loadInspectorPreferences: vi.fn(async () => saved.serialize()),
      saveInspectorPreferences: vi.fn(async () => {}),
      listInspectorApps: vi.fn(async () => discovered),
      openApp: vi.fn(async () => {}),
      appInspectorStateChanged: vi.fn(),
      onNativeSelectedInspector: vi.fn(() => () => {}),
      onNativeSelectedApp: vi.fn((callback) => {
        selectApp = callback;
        return () => {};
      }),
      listTweaks: vi.fn(
        async (): Promise<TweakList> => ({
          tweaks: [{ name: "Demo title", type: "string", value: "Cached value", default: "Default" }]
        })
      ),
      startTweakStream: vi.fn(async () => ({ streamId: "stream" })),
      stopTweakStream: vi.fn(async () => {}),
      onTweaksChanged: vi.fn(() => () => {}),
      onNativeTweaksReset: vi.fn(() => () => {}),
      nativeTweaksStateChanged: vi.fn()
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

  async function renderWaitingForTweaks() {
    const starter = {
      ...app(1, "network"),
      processName: "com.example.starter",
      packageName: "com.example.starter"
    };
    discovered = [app(10, "network")];
    vi.mocked(mocks.client.listInspectorApps).mockResolvedValueOnce([starter, ...discovered]);
    await act(async () => root.render(<App />));
    await act(async () => selectApp(discovered[0].id));
  }

  it("preserves the real Tweaks view through disconnect and PID replacement", async () => {
    await act(async () => root.render(<App />));
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    expect(input.value).toBe("Cached value");
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();

    let finish!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    discovered = [app(20)];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(input.value).toBe("Cached value");
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () =>
      finish({ tweaks: [{ name: "Demo title", type: "string", value: "Fresh value", default: "Default" }] })
    );
    expect(input.value).toBe("Fresh value");
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("keeps the launch spinner through the transition into Tweaks and shows data as soon as it loads", async () => {
    let finish!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await renderWaitingForTweaks();
    expect(container.querySelector(".inspector-loading-shell")).not.toBeNull();
    await act(async () => container.querySelector<HTMLButtonElement>(".inspector-open-app")!.click());
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    expect(container.querySelectorAll('[role="progressbar"]')).toHaveLength(1);

    discovered = [app(20)];
    await act(async () => vi.advanceTimersByTimeAsync(500));
    expect(container.querySelector(".tweaks-inspector")).not.toBeNull();
    expect(container.querySelector(".inspector-loading-shell")).toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    expect(container.querySelectorAll('[role="progressbar"]')).toHaveLength(1);
    expect(container.querySelector('[role="status"]')?.textContent).toBe("Waiting for inspector");

    await act(async () =>
      finish({ tweaks: [{ name: "Demo title", type: "string", value: "Ready", default: "Default" }] })
    );
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Ready");
    expect(container.querySelector('[role="progressbar"]')).toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
  });

  it("restores Open five seconds after the click even when the waiting view changes", async () => {
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(() => new Promise(() => {}));
    await renderWaitingForTweaks();
    await act(async () => container.querySelector<HTMLButtonElement>(".inspector-open-app")!.click());
    discovered = [app(20)];
    await act(async () => vi.advanceTimersByTimeAsync(1_500));
    expect(container.querySelector(".tweaks-inspector")).not.toBeNull();
    await act(async () => vi.advanceTimersByTimeAsync(3_499));
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    await act(async () => vi.advanceTimersByTimeAsync(1));
    expect(container.querySelector(".inspector-open-app")?.textContent).toBe("Open Demo");
    expect(container.querySelector('[role="progressbar"]')).toBeNull();
  });

  it("keeps a successfully loaded empty view through disconnect", async () => {
    vi.mocked(mocks.client.listTweaks).mockResolvedValue({ tweaks: [] });
    await act(async () => root.render(<App />));
    expect(container.textContent).toContain("No tweaks on screen");
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(container.textContent).toContain("No tweaks on screen");
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it.each([
    { packageName: "com.example.other", processName: "com.example.other", androidUserId: 0 },
    { packageName: "com.example.demo", processName: "com.example.demo", androidUserId: 10 }
  ])("does not show another app or profile's cached values while loading", async (target) => {
    await act(async () => root.render(<App />));
    const other = { ...app(20), ...target };
    discovered = [app(10), other];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    let finish!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await act(async () => selectApp(other.id));
    expect(container.querySelector('input[type="text"]')).toBeNull();
    expect(container.querySelector('[role="status"]')).not.toBeNull();
    await act(async () => finish({ tweaks: [] }));
    expect(container.textContent).toContain("No tweaks on screen");
  });
});
