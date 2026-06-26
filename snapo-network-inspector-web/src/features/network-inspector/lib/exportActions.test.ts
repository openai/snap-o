import { describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestBodies, SaveFileInput } from "../../../network/bridge-types";
import type { InspectorRecord, RequestRecord, StreamEventRecord } from "../../../network/cdp";
import { copyCurl, exportAsHar, hydrateRecordsForHar } from "./exportActions";

describe("export body readiness", () => {
  it("does not query a request body before its upload is known to be complete", async () => {
    const client = {
      loadBodies: vi.fn(),
      copyText: vi.fn(async () => undefined)
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
    expect(client.copyText).toHaveBeenCalledOnce();
  });

  it("loads only the request body when copying a completed request as curl", async () => {
    const client = {
      loadBodies: vi.fn(async () => ({ requestId: "complete", requestBody: "body" })),
      copyText: vi.fn(async () => undefined)
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
    const saved: SaveFileInput[] = [];
    const client = {
      loadBodies: vi.fn(async (input: { requestId: string }) => ({ requestId: input.requestId })),
      appVersion: vi.fn(async () => "test"),
      saveFile: vi.fn(async (input: SaveFileInput) => {
        saved.push(input);
        return { saved: true };
      })
    } as unknown as NetworkClient;
    const streaming = request("stream", {
      streamEvents: [streamEvent("data: payload")],
      streamEventCount: 1
    });

    await exportAsHar(client, [streaming], 8);

    expect(client.loadBodies).not.toHaveBeenCalled();
    const har = JSON.parse(saved[0].data) as {
      log: { entries: Array<{ request: { url: string }; response: { content: { text?: string } } }> };
    };
    expect(har.log.entries).toHaveLength(1);
    expect(har.log.entries[0].request.url).toBe("https://example.com/stream");
    expect(har.log.entries[0].response.content.text).toBeUndefined();
  });

  it("counts WebSocket preview text and omits it when it exceeds the budget", async () => {
    const socket: InspectorRecord = {
      kind: "websocket",
      server,
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

const server = { deviceId: "device", socketName: "socket", instanceId: "instance" };

function request(id: string, overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    server,
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
