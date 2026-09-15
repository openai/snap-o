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
  async function publish(connected: boolean) {
    state = { ...state, revision: state.revision + 1, connected };
    await act(async () => receive({ ...state }));
    await flush();
  }
  it("shows host startup failures instead of waiting for Android", async () => {
    container.id = "root";
    mocks.host = new ToolHost({
      request: async () => {
        throw new Error("Open this tool in the Snap-O macOS app.");
      },
      listen: () => () => {}
    });
    await act(async () => {
      await import("./tweaks-main");
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Could not connect to Snap-O");
    expect(container.textContent).toContain("Open this tool in the Snap-O macOS app.");
    expect(container.querySelector("button")?.textContent).toBe("Reload tool");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("starts the bundled tool without requesting a protocol version", async () => {
    await mount();
    expect(mocks.client.listTweaks).not.toHaveBeenCalled();
    expect(mocks.client.subscribeTweaks).toHaveBeenCalledOnce();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("applies live native picker changes to the text color", async () => {
    const colorList = (value: string): TweakList => ({
      tweaks: [{ name: "Colors/Text", type: "color", value, default: "#112233" }]
    });
    snapshot = colorList("#112233");
    let colorChanged: (event: { sessionId: string; revision: number; color: string }) => void;
    const request = vi.fn(async (command: string, _payload?: unknown): Promise<unknown> => {
      void _payload;
      return command === "hostState" ? { ...state } : undefined;
    });
    mocks.host = new ToolHost({
      request: async <T,>(command: string, payload?: unknown) => (await request(command, payload)) as T,
      listen: <T,>(name: string, callback: (value: T) => void) => {
        if (name === "host:color-changed") colorChanged = callback as typeof colorChanged;
        return () => {};
      }
    });
    vi.mocked(mocks.client.updateTweaks).mockImplementation(async ({ values }) => {
      const value = String(values["Colors/Text"]);
      onSnapshot(colorList(value));
      return { tweaks: [{ name: "Colors/Text", value, modified: true }] };
    });
    await mount();
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Colors/Text color"]')!.click());
    const session = request.mock.calls.find(([command]) => command === "openNativeColorPanel")![1] as {
      sessionId: string;
      revision: number;
    };
    for (const color of ["#FF0000FF", "#00FF0080", "#0000FFFF"]) {
      await act(async () => colorChanged({ ...session, color }));
      await flush();
      const value = color.endsWith("FF") ? color.slice(0, 7) : color;
      expect(mocks.client.updateTweaks).toHaveBeenLastCalledWith({ values: { "Colors/Text": value } });
      expect(container.querySelector<HTMLInputElement>('[aria-label="Colors/Text hex"]')?.value).toBe(value);
    }
    expect(request.mock.calls.filter(([command]) => command === "openNativeColorPanel")).toHaveLength(1);
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
  it("refreshes when the host publishes a new connection revision", async () => {
    await mount();
    await publish(true);
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
