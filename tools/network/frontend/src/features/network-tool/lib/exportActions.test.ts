import { version } from "../../../../package.json";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestBodies } from "../../../network/bridge-types";
import type { ToolRecord, RequestRecord, StreamEventRecord } from "../../../network/cdp";
import { copyCurl, exportAsHar, hydrateRecordsForHar } from "./exportActions";

describe("export body readiness", () => {
  const write = vi.fn(async (items: ClipboardItem[]) => {
    await items[0].getType("text/plain");
  });

  beforeEach(() => {
    write.mockClear();
    vi.stubGlobal("navigator", { clipboard: { write } });
    vi.stubGlobal(
      "ClipboardItem",
      class {
        constructor(private data: Record<string, Promise<Blob>>) {}
        getType(type: string): Promise<Blob> {
          return this.data[type];
        }
      }
    );
  });
  afterEach(() => vi.unstubAllGlobals());

  it("copies and exports cached data without querying an offline processId", async () => {
    const client = {
      loadBodies: vi.fn(),
      saveFile: vi.fn(async () => true)
    } as unknown as NetworkClient;
    const complete = request("offline", {
      method: "POST",
      requestHasPostData: true,
      requestBodySize: 4,
      hasReceivedResponse: true,
      responseBody: "cached-response"
    });
    await copyCurl(client, complete, false);
    await exportAsHar(client, [complete], undefined, false);
    expect(client.loadBodies).not.toHaveBeenCalled();
    expect(write).toHaveBeenCalledOnce();
    const { name, data } = vi.mocked(client.saveFile).mock.calls[0][0];
    expect(name).toMatch(/\.har$/u);
    expect(data.type).toBe("application/har+json");
    const har = JSON.parse(await data.text());
    expect(har.log.creator.version).toBe(version);
    expect(har.log.entries[0].response.content.text).toBe("cached-response");
  });
  it("does not query a request body before its upload is known to be complete", async () => {
    const client = {
      loadBodies: vi.fn()
    } as unknown as NetworkClient;
    const pending = request("pending", {
      method: "POST",
      status: { kind: "pending" },
      endedAt: undefined,
      requestHasPostData: true,
      requestBodySize: 4,
      hasReceivedResponse: false
    });

    await copyCurl(client, pending);

    expect(client.loadBodies).not.toHaveBeenCalled();
    expect(write).toHaveBeenCalledOnce();
  });

  it("loads only the request body when copying a completed request as curl", async () => {
    const client = {
      loadBodies: vi.fn(async () => ({ requestId: "complete", requestBody: "body" }))
    } as unknown as NetworkClient;
    const complete = request("complete", {
      method: "POST",
      requestHasPostData: true,
      requestBodySize: 4,
      hasReceivedResponse: true
    });

    await copyCurl(client, complete);

    expect(client.loadBodies).toHaveBeenCalledWith(
      expect.objectContaining({ includeRequestBody: true, includeResponseBody: false })
    );
  });

  it("starts writing before a delayed body resolves and includes that body in the clipboard item", async () => {
    const body = deferred<RequestBodies>();
    const client = { loadBodies: vi.fn(() => body.promise) } as unknown as NetworkClient;
    const complete = request("delayed", { method: "POST", hasReceivedResponse: true });

    const copying = copyCurl(client, complete);

    // The write must start in the calling event handler, without awaiting body loading.
    expect(write).toHaveBeenCalledOnce();
    const item = write.mock.calls[0][0][0];
    const ready = vi.fn();
    void copying.then(ready);
    await nextTask();
    expect(ready).not.toHaveBeenCalled();

    body.resolve({ requestId: "delayed", requestBody: "late body" });
    await copying;
    const copied = await item.getType("text/plain");
    expect(copied.type).toBe("text/plain");
    expect(await copied.text()).toContain("--data-binary 'late body'");
    expect(await copied.text()).toContain("--url 'https://example.com/delayed'");
  });

  it("still copies request metadata if loading the body fails", async () => {
    const client = { loadBodies: vi.fn().mockRejectedValue(new Error("Body unavailable")) } as unknown as NetworkClient;

    await copyCurl(client, request("expired", { method: "POST", hasReceivedResponse: true }));

    const copied = await write.mock.calls[0][0][0].getType("text/plain");
    expect(await copied.text()).toContain("--url 'https://example.com/expired'");
    expect(await copied.text()).not.toContain("--data-binary");
  });
});

describe("HAR body hydration budget", () => {
  it("counts existing cached bodies before hydrating missing bodies", async () => {
    const loadBodies = vi.fn(
      async (input: { requestId: string }): Promise<RequestBodies> => ({
        requestId: input.requestId,
        responseBody: "new"
      })
    );
    const cached = request("cached", { requestBody: "12", responseBody: "12" });
    const missing = request("missing");

    const result = await hydrateRecordsForHar({ loadBodies }, [cached, missing], 10);

    expect(result[0]).toMatchObject({ requestBody: "12", responseBody: "12" });
    expect(result[1]).not.toHaveProperty("responseBody");
    expect(loadBodies).toHaveBeenCalledTimes(1);
  });

  it("stops accumulating hydrated bodies after the aggregate budget is reached", async () => {
    const loadBodies = vi.fn(
      async (input: { requestId: string }): Promise<RequestBodies> => ({
        requestId: input.requestId,
        responseBody: input.requestId === "first" ? "1234" : "ab"
      })
    );

    const result = await hydrateRecordsForHar(
      { loadBodies },
      [request("first"), request("overflow"), request("in-flight"), request("not-scheduled")],
      10
    );

    expect(result[0]).toMatchObject({ responseBody: "1234" });
    expect(result[1]).not.toHaveProperty("responseBody");
    expect(result[2]).not.toHaveProperty("responseBody");
    expect(result[3]).not.toHaveProperty("responseBody");
    expect(loadBodies.mock.calls.map(([input]) => input.requestId)).toEqual(["first", "overflow", "in-flight"]);
  });

  it("hydrates each ordered batch concurrently", async () => {
    const pending = new Map<string, ReturnType<typeof deferred<RequestBodies>>>();
    const loadBodies = vi.fn((input: { requestId: string }) => {
      const result = deferred<RequestBodies>();
      pending.set(input.requestId, result);
      return result.promise;
    });
    const hydration = hydrateRecordsForHar(
      { loadBodies },
      [request("one"), request("two"), request("three"), request("four")],
      100
    );

    await Promise.resolve();
    expect([...pending.keys()]).toEqual(["one", "two", "three"]);
    for (const id of ["one", "two", "three"]) {
      pending.get(id)?.resolve({ requestId: id, responseBody: id });
    }
    await nextTask();
    expect([...pending.keys()]).toEqual(["one", "two", "three", "four"]);
    pending.get("four")?.resolve({ requestId: "four", responseBody: "four" });

    const result = await hydration;
    expect(result.map((record) => (record.kind === "request" ? record.responseBody : null))).toEqual([
      "one",
      "two",
      "three",
      "four"
    ]);
  });

  it("omits retained SSE text that does not fit while preserving valid HAR metadata", async () => {
    const saved: Parameters<NetworkClient["saveFile"]>[0][] = [];
    const client = {
      loadBodies: vi.fn(async (input: { requestId: string }) => ({ requestId: input.requestId })),
      saveFile: vi.fn(async (input: Parameters<NetworkClient["saveFile"]>[0]) => {
        saved.push(input);
        return true;
      })
    } as unknown as NetworkClient;
    const streaming = request("stream", {
      streamEvents: [streamEvent("data: payload")],
      streamEventCount: 1
    });

    await exportAsHar(client, [streaming], 8);

    expect(client.loadBodies).not.toHaveBeenCalled();
    const har = JSON.parse(await saved[0].data.text()) as {
      log: { entries: Array<{ request: { url: string }; response: { content: { text?: string } } }> };
    };
    expect(har.log.entries).toHaveLength(1);
    expect(har.log.entries[0].request.url).toBe("https://example.com/stream");
    expect(har.log.entries[0].response.content.text).toBeUndefined();
  });

  it("counts WebSocket preview text and omits it when it exceeds the budget", async () => {
    const socket: ToolRecord = {
      kind: "websocket",
      processId,
      socketId: "socket",
      method: "WS",
      url: "wss://example.com/socket",
      requestHeaders: [],
      responseHeaders: [],
      status: { kind: "success", code: 101 },
      startedAt: 1,
      updatedAt: 2,
      messages: [
        {
          id: "message",
          direction: "incoming",
          opcode: "text",
          preview: "payload",
          timestamp: 2
        }
      ],
      messageCount: 1
    };

    const [result] = await hydrateRecordsForHar({ loadBodies: vi.fn() }, [socket], 4);

    expect(result.kind).toBe("websocket");
    if (result.kind === "websocket") expect(result.messages[0].preview).toBeUndefined();
  });
});

const processId = "process-1";

function request(id: string, overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    processId,
    requestId: id,
    method: "GET",
    url: `https://example.com/${id}`,
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "success", code: 200 },
    startedAt: 1,
    endedAt: 2,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 2,
    ...overrides
  };
}

function streamEvent(raw: string): StreamEventRecord {
  return {
    sequence: 1,
    timestamp: 1,
    raw
  };
}

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolvePromise: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    resolvePromise = resolve;
  });
  return { promise, resolve: resolvePromise };
}

function nextTask(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
