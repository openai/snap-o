// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TweakList } from "./types";
import type { TweaksClient } from "./features/tweaks-inspector/client";
import { InspectorHost, type Host, type ProcessManifest, type InspectorDescriptor } from "@snap-o/host";
import { TweaksApp } from "./TweaksApp";

const mocks = vi.hoisted(() => ({ client: null as unknown as TweaksClient, host: null as unknown as Host }));
vi.mock("@snap-o/host", async (original) => ({
  ...(await original<typeof import("@snap-o/host")>()),
  get host() {
    return mocks.host;
  }
}));
vi.mock("./features/tweaks-inspector/client", () => ({ createTweaksClient: () => mocks.client }));
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
    inspector: InspectorDescriptor;
  };
  let receive: (value: typeof state) => void;
  beforeEach(() => {
    vi.useFakeTimers();
    state = {
      revision: 1,
      connected: true,
      baseURL: "http://127.0.0.1:1234/",
      manifest: {
        version: 1,
        pid: 20,
        app: { name: "Demo", packageName: "com.example.demo", revision: "1", inspectors: [] }
      },
      inspector: { id: "tweaks", name: "Tweaks", protocolVersion: 7 }
    };
    mocks.host = new InspectorHost({
      request: async <T,>(command: string) => (command === "hostState" ? { ...state } : undefined) as T,
      listen: <T,>(name: string, callback: (value: T) => void) => {
        if (name === "host:connection") receive = callback as (value: typeof state) => void;
        return () => {};
      }
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => Response.json({ name: "Demo", packageName: "com.example.demo", protocolVersion: 5 }))
    );
    mocks.client = {
      listTweaks: vi.fn(async () => list("Cached value")),
      startTweakStream: vi.fn(async () => ({ streamId: "stream" })),
      stopTweakStream: vi.fn(async () => {}),
      onTweaksChanged: vi.fn(() => () => {}),
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
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    let reply!: (value: TweakList) => void;
    vi.mocked(mocks.client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          reply = resolve;
        })
    );
    await publish(true);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => reply(list("Fresh value")));
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
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(1);
    expect(mocks.client.startTweakStream).toHaveBeenCalledTimes(1);
    await publish(true);
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(2);
    expect(mocks.client.startTweakStream).toHaveBeenCalledTimes(2);
  });
  it("refreshes when the host changes the forwarded port", async () => {
    await mount();
    await publish(true, "http://127.0.0.1:4321/");
    expect(mocks.client.listTweaks).toHaveBeenCalledTimes(2);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("retains an empty snapshot while disconnected", async () => {
    vi.mocked(mocks.client.listTweaks).mockResolvedValue({ tweaks: [] });
    await mount();
    await publish(false);
    expect(container.textContent).toContain("No tweaks on screen");
  });
});
