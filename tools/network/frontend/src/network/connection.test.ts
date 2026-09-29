import { afterEach, describe, expect, it, vi } from "vitest";
import { NetworkConnection } from "./connection";
import type { StreamEvent } from "./bridge-types";

const endpoint = "/api/";
const metadata = {
  signal: new AbortController().signal,
  name: "Demo",
  packageName: "example.demo",
  processIdentity: "boot:20:123"
};
const event = (sequence: number, name = "request") => ({
  method: "Network.loadingFinished",
  params: { requestId: name },
  snapoSequence: sequence
});
class Events extends EventTarget {
  close = vi.fn();
  send(sequence: number) {
    this.dispatchEvent(
      new MessageEvent("message", { data: JSON.stringify(event(sequence)), lastEventId: String(sequence) })
    );
  }
}
const connections: NetworkConnection[] = [];
afterEach(() => {
  for (const connection of connections.splice(0)) connection.close();
  vi.useRealTimers();
});
function setup(history: (events: Events) => Response | Promise<Response>) {
  const events = new Events();
  const received: StreamEvent[] = [];
  const closed = vi.fn();
  const fetchRequest = vi.fn<typeof fetch>(async (url, init) => {
    if (String(url).endsWith("/network")) {
      expect(init?.headers).toEqual({ Accept: "application/x-ndjson" });
      return history(events);
    }
    return Response.json({ body: "response", base64Encoded: false });
  });
  const eventSource = vi.fn((url: string) => {
    expect(url).toBe(endpoint + "network");
    queueMicrotask(() => events.dispatchEvent(new Event("open")));
    return events as unknown as EventSource;
  });
  const connection = new NetworkConnection(metadata, (value) => received.push(value), closed, {
    fetch: fetchRequest,
    eventSource
  });
  connections.push(connection);
  return { connection, events, received, fetchRequest, eventSource, closed };
}
function snapshot(text = "") {
  return new Response(text, { headers: { "Content-Type": "application/x-ndjson" } });
}

describe("direct Network HTTP and SSE connection", () => {
  it("joins a streamed UTF-8 snapshot with buffered live events without duplicates", async () => {
    const { connection, events, received } = setup((stream) => {
      stream.send(2);
      stream.send(3);
      const bytes = new TextEncoder().encode(JSON.stringify(event(2, "café")) + "\n");
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
          controller.close();
        }
      });
      return new Response(body, { headers: { "Content-Type": "application/x-ndjson" } });
    });
    await connection.start();
    events.send(4);
    events.send(4);
    expect(received.map((value) => value.message.snapoSequence)).toEqual([2, 3, 4]);
    expect(received[0].message.params?.requestId).toBe("café");
    expect(received[0].processId).toBe("boot:20:123");
  });
  it("keeps buffered live events when history is empty and ignores heartbeats", async () => {
    const { connection, events, received } = setup((stream) => {
      stream.send(119);
      stream.send(120);
      return snapshot();
    });
    await connection.start();
    events.dispatchEvent(new Event("heartbeat"));
    events.send(120);
    events.send(121);
    expect(received.map((value) => value.message.snapoSequence)).toEqual([119, 120, 121]);
  });
  it("a new connection starts with its own event sequence", async () => {
    const first = setup(() => snapshot(JSON.stringify(event(120)) + "\n"));
    await first.connection.start();
    first.connection.close();
    const second = setup(() => snapshot(JSON.stringify(event(1)) + "\n"));
    await second.connection.start();
    expect(second.received.map((value) => value.message.snapoSequence)).toEqual([1]);
  });
  it.each([
    JSON.stringify(event(1)),
    JSON.stringify({ ...event(1), snapoSequence: -1 }) + "\n",
    JSON.stringify({ ...event(1), snapoSequence: undefined }) + "\n"
  ])("rejects incomplete or invalid history (%s)", async (body) => {
    const { connection, events } = setup(() => snapshot(body));
    await expect(connection.start()).rejects.toThrow();
    expect(events.close).toHaveBeenCalled();
  });
  it("closes an overflowing live buffer instead of dropping history", async () => {
    const { connection, events } = setup((stream) => {
      for (let index = 0; index <= 4096; index++) stream.send(index);
      return snapshot();
    });
    await expect(connection.start()).rejects.toThrow();
    expect(events.close).toHaveBeenCalled();
  });
  it("closes EventSource on failure so the controller can request a new snapshot", async () => {
    const { connection, events, closed } = setup(() => snapshot());
    await connection.start();
    events.dispatchEvent(new Event("error"));
    expect(events.close).toHaveBeenCalledTimes(1);
    expect(closed).toHaveBeenCalledWith({ streamId: connection.id });
    await expect(connection.loadBodies({ processId: "boot:20:123", requestId: "one" })).rejects.toThrow("disconnected");
  });
  it("uses the tool URL for body reads and encodes request IDs", async () => {
    const { connection, fetchRequest } = setup(() => snapshot());
    await connection.start();
    const bodies = await connection.loadBodies({
      processId: "boot:20:123",
      requestId: "one/two+three",
      includeRequestBody: false
    });
    expect(bodies.responseBody).toBe("response");
    expect(fetchRequest).toHaveBeenLastCalledWith(
      endpoint + "network/requests/one%2Ftwo%2Bthree/response-body",
      expect.anything()
    );
    await expect(connection.loadBodies({ requestId: "one", processId: "older" })).rejects.toThrow(
      "earlier app process"
    );
  });
});

it("posts literal body searches and rejects invalid snippets and older servers", async () => {
  const { connection, fetchRequest } = setup(() => snapshot());
  const query = { requestIds: ["one"], terms: ["needle"] };
  const match = {
    requestId: "one",
    request: { terms: [], complete: true },
    response: { terms: ["needle"], complete: true, snippet: "a needle" }
  };
  fetchRequest.mockResolvedValueOnce(Response.json({ results: [match] }));
  await expect(connection.searchBodies(query, new AbortController().signal)).resolves.toEqual({ results: [match] });
  expect(fetchRequest).toHaveBeenLastCalledWith(
    "/api/network/search",
    expect.objectContaining({ method: "POST", body: JSON.stringify(query) })
  );
  fetchRequest.mockResolvedValueOnce(
    Response.json({ results: [{ ...match, response: { ...match.response, snippet: {} } }] })
  );
  await expect(connection.searchBodies(query, new AbortController().signal)).resolves.toEqual({ results: [] });
  fetchRequest.mockResolvedValueOnce(new Response("missing", { status: 404 }));
  await expect(connection.searchBodies(query, new AbortController().signal)).resolves.toEqual({ results: [] });
});

const query = { requestIds: ["one"], terms: ["needle"] };
const signal = () => new AbortController().signal;

it.each([429, 503, new TypeError("network"), new DOMException("timeout", "TimeoutError")])(
  "retries temporary search failure %s",
  async (error) => {
    vi.useFakeTimers();
    const { connection, fetchRequest } = setup(() => snapshot());
    if (typeof error === "number") fetchRequest.mockResolvedValueOnce(new Response(null, { status: error }));
    else fetchRequest.mockRejectedValueOnce(error);
    fetchRequest.mockResolvedValue(Response.json({ results: [] }));
    const pending = connection.searchBodies(query, signal());
    await vi.advanceTimersByTimeAsync(500);
    await pending;
    expect(fetchRequest).toHaveBeenCalledTimes(2);
    expect(fetchRequest.mock.calls[1][1]?.body).toEqual(fetchRequest.mock.calls[0][1]?.body);
  }
);

it("cancels pending search retries", async () => {
  vi.useFakeTimers();
  const { connection, fetchRequest } = setup(() => snapshot());
  fetchRequest.mockResolvedValue(new Response(null, { status: 429 }));
  const abort = new AbortController();
  const rejected = expect(connection.searchBodies(query, abort.signal)).rejects.toThrow();
  await vi.advanceTimersByTimeAsync(0);
  abort.abort();
  await vi.advanceTimersByTimeAsync(500);
  await rejected;
  expect(fetchRequest).toHaveBeenCalledTimes(1);
});

it.each([400, 404])("does not retry search status %s", async (status) => {
  const { connection, fetchRequest } = setup(() => snapshot());
  fetchRequest.mockResolvedValue(new Response(null, { status }));
  expect(await connection.searchBodies(query, signal())).toEqual({ results: [] });
  expect(fetchRequest).toHaveBeenCalledTimes(1);
});

it.each(["界", "\u0001"])("fits maximum %s search replies within the size limit", async (character) => {
  const { connection, fetchRequest } = setup(() => snapshot());
  const strings = (count: number, size: number) =>
    Array.from({ length: count }, (_, i) => character.repeat(size - 2) + String(i).padStart(2, "0"));
  const query = { requestIds: strings(33, 512), terms: strings(64, 256) };
  fetchRequest.mockImplementation(async (_, init) => {
    const batch = JSON.parse(init!.body as string);
    const body = { terms: batch.terms, complete: true, snippet: character.repeat(160) };
    return Response.json({
      results: batch.requestIds.map((requestId: string) => ({ requestId, request: body, response: body }))
    });
  });
  const published = vi.fn();
  const reply = await connection.searchBodies(query, signal(), published);
  expect(reply.results).toHaveLength(33);
  expect(reply.results.every((result) => result.response.terms.length === 64)).toBe(true);
  expect(published.mock.calls.flatMap(([batch]) => batch.results)).toEqual(reply.results);
});
