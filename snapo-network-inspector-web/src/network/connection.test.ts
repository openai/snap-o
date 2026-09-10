import { afterEach, describe, expect, it, vi } from "vitest";
import { NetworkConnection } from "./connection";
import type { StreamEvent } from "./bridge-types";

const baseURL = "http://127.0.0.1:1234/";
const metadata = {
  name: "Demo",
  packageName: "example.demo",
  protocolVersion: 2,
  serverStartWallMs: 100,
  serverStartMonoNs: 200
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
});
function setup(history: (events: Events) => Response | Promise<Response>) {
  const events = new Events();
  const received: StreamEvent[] = [];
  const status = vi.fn();
  const fetchRequest = vi.fn<typeof fetch>(async (url, init) => {
    if (String(url).endsWith("/network")) {
      expect(init?.headers).toEqual({ Accept: "application/x-ndjson" });
      return history(events);
    }
    return Response.json({ body: "response", base64Encoded: false });
  });
  const eventSource = vi.fn((url: string) => {
    expect(url).toBe(baseURL + "network");
    queueMicrotask(() => events.dispatchEvent(new Event("open")));
    return events as unknown as EventSource;
  });
  const connection = new NetworkConnection(baseURL, metadata, (value) => received.push(value), status, {
    fetch: fetchRequest,
    eventSource
  });
  connections.push(connection);
  return { connection, events, received, fetchRequest, eventSource, status };
}
function snapshot(text = "", sequence = "0") {
  return new Response(text, { headers: { "Content-Type": "application/x-ndjson", "SnapO-Sequence": sequence } });
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
      return new Response(body, { headers: { "Content-Type": "application/x-ndjson", "SnapO-Sequence": "2" } });
    });
    await connection.start();
    events.send(4);
    expect(received.map((value) => value.message.snapoSequence)).toEqual([2, 3, 4]);
    expect(received[0].message.params?.requestId).toBe("café");
    expect(received[0].processId).toBe("100:200");
  });
  it.each([
    [JSON.stringify(event(1)), "1"],
    [JSON.stringify(event(2)) + "\n", "1"],
    [JSON.stringify(event(1)) + "\n", "missing"]
  ])("rejects incomplete or inconsistent history (%s)", async (body, sequence) => {
    const { connection, events } = setup(() => snapshot(body, sequence));
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
    const { connection, events, status } = setup(() => snapshot());
    await connection.start();
    events.dispatchEvent(new Event("error"));
    expect(events.close).toHaveBeenCalledTimes(1);
    expect(status).toHaveBeenCalledWith(expect.objectContaining({ state: "exit" }));
    await expect(connection.loadBodies({ processId: "100:200", requestId: "one" })).rejects.toThrow("disconnected");
  });
  it("uses the bound endpoint for body reads and encodes request IDs", async () => {
    const { connection, fetchRequest } = setup(() => snapshot());
    await connection.start();
    const bodies = await connection.loadBodies({
      processId: "100:200",
      requestId: "one/two+three",
      includeRequestBody: false
    });
    expect(bodies.responseBody).toBe("response");
    expect(fetchRequest).toHaveBeenLastCalledWith(
      baseURL + "network/requests/one%2Ftwo%2Bthree/response-body",
      expect.anything()
    );
    await expect(connection.loadBodies({ requestId: "one", processId: "older" })).rejects.toThrow(
      "earlier app process"
    );
  });
});
