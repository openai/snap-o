// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TweakList } from "./types";
import type { TweaksClient } from "./features/tweaks-tool/client";
import { ToolHost, type Host } from "@snap-o/tool-host";
type ToolDescriptor = { id: string; name: string };
type ProcessManifest = {
  version: number;
  pid: number;
  processIdentity: string;
  app: { name: string; packageName: string; revision: string; inspectors: ToolDescriptor[] };
};
import { TweaksApp } from "./TweaksApp";

const mocks = vi.hoisted(() => ({ client: null as unknown as TweaksClient, host: null as unknown as Host }));
vi.mock("@snap-o/tool-host", async (original) => ({
  ...(await original<typeof import("@snap-o/tool-host")>()),
  get host() {
    return mocks.host;
  }
}));
vi.mock("./features/tweaks-tool/client", () => ({ createTweaksClient: () => mocks.client }));
const list = (value: string): TweakList => ({
  tweaks: [{ name: "Demo title", type: "string", value, default: "Default" }]
});

describe("Tweaks frontend with the shared host", () => {
  let container: HTMLDivElement;
  let state: {
    revision: number;
    connected: boolean;
    baseURL: string;
    manifest: ProcessManifest;
    inspector: ToolDescriptor;
  };
  let receive: (value: typeof state) => void;
  let snapshot: TweakList | null;
  let onSnapshot: (snapshot: TweakList) => void;
  beforeEach(() => {
    vi.useFakeTimers();
    snapshot = list("Cached value");
    state = {
      revision: 1,
      connected: true,
      baseURL: "http://127.0.0.1:1234/",
      manifest: {
        version: 1,
        pid: 20,
        processIdentity: "boot:20:123",
        app: { name: "Demo", packageName: "com.example.demo", revision: "1", inspectors: [] }
      },
      inspector: { id: "tweaks", name: "Tweaks" }
    };
    mocks.host = new ToolHost({
      request: async <T,>(command: string) => (command === "hostState" ? { ...state } : undefined) as T,
      listen: <T,>(name: string, callback: (value: T) => void) => {
        if (name === "host:connection") receive = callback as (value: typeof state) => void;
        return () => {};
      }
    });
    vi.stubGlobal("fetch", vi.fn());
    mocks.client = {
      listTweaks: vi.fn(async () => list("Cached value")),
      subscribeTweaks: vi.fn((_connection, callback) => {
        onSnapshot = callback;
        const initial = snapshot;
        if (initial) queueMicrotask(() => callback(initial));
        return vi.fn();
      }),
      updateTweaks: vi.fn(async () => ({ tweaks: [] })),
      invokeTweakAction: vi.fn(async () => {}),
      openExternal: vi.fn(async () => {}),
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
  async function mount() {
    await act(async () => render(<TweaksApp />, container));
    await flush();
  }
  async function publish(connected: boolean, baseURL = state.baseURL) {
    state = { ...state, revision: state.revision + 1, connected, baseURL };
    await act(async () => receive({ ...state }));
    await flush();
  }
  it("starts the bundled tool without requesting a protocol version", async () => {
    await mount();
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(mocks.client.subscribeTweaks).toHaveBeenCalledOnce();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("preserves values while disconnected and refreshes after reconnect", async () => {
    await mount();
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    expect(input.value).toBe("Cached value");
    await publish(false);
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000);
    });
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    snapshot = null;
    await publish(true);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => onSnapshot(list("Fresh value")));
    expect(input.value).toBe("Fresh value");
    await flush();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });
  it("waits for a host connection and ignores repeated unchanged updates", async () => {
    state.connected = false;
    await mount();
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    await publish(true);
    await act(async () => receive({ ...state }));
    await flush();
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(mocks.client.subscribeTweaks).toHaveBeenCalledTimes(1);
    await publish(true);
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(mocks.client.subscribeTweaks).toHaveBeenCalledTimes(2);
  });
  it("refreshes when the host changes the forwarded port", async () => {
    await mount();
    await publish(true, "http://127.0.0.1:4321/");
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("retains an empty snapshot while disconnected", async () => {
    snapshot = { tweaks: [] };
    await mount();
    await publish(false);
    expect(container.textContent).toContain("No tweaks on screen");
  });
});
