// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient, type NetworkClient } from "./client";
import { host } from "@snap-o/tool-host";
import { NetworkStreamController } from "./stream-controller";
import { createEmptyToolState, reduceCdpMessage } from "./cdp";
import { bodySearchMatches, searchAndroidCapture, searchLocalCapture, type BodySearchCache } from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";

describe("browser network client", () => {
  let client: NetworkClient;
  beforeEach(() => {
    const values = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      clear: () => values.clear()
    });
    localStorage.clear();
    vi.spyOn(host, "addEventListener").mockImplementation(() => {});
    client = createNetworkClient();
  });
  afterEach(() => {
    client?.dispose();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });
  it("persists exclusion filters across clients without losing successive edits", () => {
    client.addExclusionFilter("-one.test");
    client.addExclusionFilter("-two.test");
    const second = createNetworkClient();
    expect(second.listExclusionFilters()).toEqual(["-one.test", "-two.test"]);
    second.dispose();
    client.removeExclusionFilter("-one.test");
    expect(client.listExclusionFilters()).toEqual(["-two.test"]);
    localStorage.setItem("network.exclusionFilters", "invalid");
    expect(client.listExclusionFilters()).toEqual([]);
  });
  it("handles unavailable storage reads and reports failed writes synchronously", () => {
    vi.spyOn(localStorage, "getItem").mockImplementation(() => {
      throw new Error("Unavailable");
    });
    vi.spyOn(localStorage, "setItem").mockImplementation(() => {
      throw new Error("Unavailable");
    });
    expect(client.listExclusionFilters()).toEqual([]);
    expect(() => client.addExclusionFilter("-example.test")).toThrow("Unavailable");
    expect(() => client.removeExclusionFilter("-example.test")).toThrow("Unavailable");
  });
  it("uses the browser clipboard and shared host file export", async () => {
    const copy = vi.fn(async () => {});
    vi.stubGlobal("navigator", { clipboard: { writeText: copy } });
    const save = vi.spyOn(host, "saveFile").mockResolvedValue(true);
    await client.copyText("request");
    expect(copy).toHaveBeenCalledWith("request");
    const input = { name: "capture.har", data: new Blob(["{}"], { type: "application/har+json" }) };
    expect(await client.saveFile(input)).toBe(true);
    expect(save).toHaveBeenCalledWith(input);
    expect(save.mock.calls[0][0].data).toBe(input.data);
    save.mockResolvedValue(false);
    expect(await client.saveFile(input)).toBe(false);
  });
  it("rejects requests while disconnected", async () => {
    const abort = new AbortController();
    abort.abort();
    await expect(
      client.startStream({
        signal: abort.signal,
        processIdentity: "boot:20:123"
      })
    ).rejects.toThrow("disconnected");
    await expect(client.loadBodies({ processId: "process-1", requestId: "one" })).rejects.toThrow("disconnected");
  });
  it.each(["retry", "cancel"])("handles %s while reconnecting a body search", async (action) => {
    vi.useFakeTimers();
    const input = { processIdentity: "current", signal: new AbortController().signal };
    const abort = new AbortController();
    const cache: BodySearchCache = new Map();
    let state = createEmptyToolState();
    const records = () => [...state.requests.values()];
    const unsubscribe = client.onEvent((event) => {
      state = reduceCdpMessage(state, event.processId, event.message);
      void searchLocalCapture(records(), ["needle"], abort.signal, cache, () => {}).catch(() => {});
    });
    const streams: EventTarget[] = [];
    vi.stubGlobal(
      "EventSource",
      class extends EventTarget {
        constructor() {
          super();
          streams.push(this);
          queueMicrotask(() => this.dispatchEvent(new Event("open")));
        }
        close() {}
      }
    );
    const history =
      JSON.stringify({
        method: "Network.loadingFinished",
        params: { requestId: "one", timestamp: 1, encodedDataLength: 8 },
        snapoSequence: 1
      }) + "\n";
    const searches: AbortSignal[] = [];
    let ready = false;
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      if (url.endsWith("/network")) {
        return new Response(history, { headers: { "Content-Type": "application/x-ndjson" } });
      }
      const signal = init.signal!;
      searches.push(signal);
      if (!ready)
        return new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason), { once: true });
        });
      return Response.json({
        results: [
          {
            requestId: "one",
            request: { terms: [], complete: true },
            response: { terms: ["needle"], complete: true }
          }
        ]
      });
    });
    const calls = vi.spyOn(client, "searchBodies");
    const controller = new NetworkStreamController(client, input, () => {}, { retryDelaysMs: [1200] });
    controller.start();
    await vi.advanceTimersByTimeAsync(0);
    const work = searchAndroidCapture(["needle"], client, input, abort.signal, cache, () => {});
    const stopped = expect(work).rejects.toMatchObject({ name: "AbortError" });
    try {
      expect(searches).toHaveLength(1);
      streams[0].dispatchEvent(new Event("error"));
      await vi.advanceTimersByTimeAsync(1000);
      expect(searches[0].aborted).toBe(true);
      expect(calls).toHaveBeenCalledTimes(3);
      expect([...cache.values()][0].remote).toBeUndefined();
      if (action === "cancel") abort.abort();
      ready = true;
      await vi.advanceTimersByTimeAsync(1000);
      expect(streams).toHaveLength(2);
      expect(searches).toHaveLength(action === "cancel" ? 1 : 2);
      expect(filterRecords(records(), "needle", false, [], bodySearchMatches(cache))).toHaveLength(
        action === "cancel" ? 0 : 1
      );
      if (action === "cancel") expect(calls).toHaveBeenCalledTimes(3);
    } finally {
      abort.abort();
      controller.dispose();
      unsubscribe();
      await vi.advanceTimersByTimeAsync(500);
      await stopped;
      vi.useRealTimers();
    }
  });

  it("keeps one stream, binds its connection, and ignores cleanup from an older stream", async () => {
    const input = {
      processIdentity: "boot:20:123",
      signal: new AbortController().signal
    };
    vi.spyOn(host, "connection", "get").mockReturnValue(input);
    const streams: Events[] = [];
    class Events extends EventTarget {
      close = vi.fn();
      constructor(readonly url: string) {
        super();
        streams.push(this);
        queueMicrotask(() => this.dispatchEvent(new Event("open")));
      }
    }
    vi.stubGlobal("EventSource", Events);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) =>
        url.endsWith("/network")
          ? new Response("", { headers: { "Content-Type": "application/x-ndjson" } })
          : Response.json({ body: "current body", base64Encoded: false })
      )
    );
    const first = await client.startStream(input);
    const second = await client.startStream(input);
    expect(streams[0].url).toBe("/api/network");
    expect(streams[0].close).toHaveBeenCalledOnce();
    await client.stopStream(first.streamId);
    expect(streams[1].close).not.toHaveBeenCalled();
    const abort = new AbortController();
    abort.abort();
    await expect(client.startStream({ ...input, signal: abort.signal })).rejects.toThrow("disconnected");
    expect(streams[1].close).not.toHaveBeenCalled();
    expect(
      await client.loadBodies({ processId: input.processIdentity, requestId: "one", includeRequestBody: false })
    ).toMatchObject({ responseBody: "current body" });
    await client.stopStream(second.streamId);
    expect(streams[1].close).toHaveBeenCalledOnce();
    client.dispose();
    await expect(client.startStream(input)).rejects.toThrow("disconnected");
  });
});
