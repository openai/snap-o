// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { InspectableApp, TweakList } from "./network/bridge-types";
import type { NetworkClient } from "./network/client";
import { InspectorRestoration } from "./features/app-inspector/restoration";
import { App } from "./App";

const mocks = vi.hoisted(() => ({ client: null as unknown as NetworkClient }));
vi.mock("./network/client", () => ({ createNetworkClient: () => mocks.client }));
vi.mock("./features/network-inspector/hooks/useNetworkInspectorModel", () => ({
  useNetworkInspectorModel: () => ({})
}));
vi.mock("./features/network-inspector/NetworkInspectorApp", () => ({ NetworkInspectorApp: () => null }));

function app(pid: number): InspectableApp {
  return {
    id: `phone:pid:${pid}`,
    name: "Demo",
    packageName: "com.example.demo",
    processName: "com.example.demo",
    deviceId: "phone",
    deviceDisplayTitle: "Phone",
    inspectors: [
      { kind: "tweaks", protocolVersion: 4, server: { deviceId: "phone", socketName: `snapo_tweaks_${pid}` } }
    ]
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

  it("keeps a successfully loaded empty view through disconnect", async () => {
    vi.mocked(mocks.client.listTweaks).mockResolvedValue({ tweaks: [] });
    await act(async () => root.render(<App />));
    expect(container.textContent).toContain("No tweaks on screen");
    discovered = [];
    await act(async () => vi.advanceTimersByTimeAsync(2_500));
    expect(container.textContent).toContain("No tweaks on screen");
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it("does not show another app's cached values while loading", async () => {
    await act(async () => root.render(<App />));
    const other = { ...app(20), packageName: "com.example.other", processName: "com.example.other" };
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
