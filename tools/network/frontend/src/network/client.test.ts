// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient, type NetworkClient } from "./client";
import { host } from "@snap-o/tool-host";

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
  it("uses the shared host for clipboard and file export", async () => {
    const copy = vi.spyOn(host, "copyText").mockResolvedValue();
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
        baseURL: "http://127.0.0.1:1234/",
        signal: abort.signal,
        processIdentity: "boot:20:123"
      })
    ).rejects.toThrow("disconnected");
    await expect(client.loadBodies({ processId: "process-1", requestId: "one" })).rejects.toThrow("disconnected");
  });
  it("keeps one stream, binds its connection, and ignores cleanup from an older stream", async () => {
    const input = {
      baseURL: "http://127.0.0.1:1234/",
      processIdentity: "boot:20:123",
      signal: new AbortController().signal
    };
    vi.spyOn(host, "connection", "get").mockReturnValue({ ...input, baseURL: "http://127.0.0.1:9999/" });
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
          ? new Response("", { headers: { "Content-Type": "application/x-ndjson", "SnapO-Sequence": "0" } })
          : Response.json({ body: "current body", base64Encoded: false })
      )
    );
    const first = await client.startStream(input);
    const second = await client.startStream(input);
    expect(streams[0].url).toBe(input.baseURL + "network");
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
