import { describe, expect, it } from "vitest";
import type { InspectorRecord, RequestRecord, WebSocketRecord } from "../../../network/cdp";
import { matchesNetworkSearch, parseNetworkSearchQuery } from "./search";

describe("network inspector search", () => {
  it("does not change HTTP matches when lazy bodies are hydrated", () => {
    const bodyless = request();
    const hydrated: RequestRecord = {
      ...bodyless,
      requestBody: "selected-only-request-marker",
      responseBody: "cached-response-marker"
    };

    for (const searchText of ["selected-only-request-marker", "cached-response-marker"]) {
      const query = parseNetworkSearchQuery(searchText);
      expect(matchesNetworkSearch(bodyless, query)).toBe(false);
      expect(matchesNetworkSearch(hydrated, query)).toBe(false);
    }
  });

  it("searches deterministic request metadata, headers, status, and retained stream events", () => {
    const record = request({
      method: "POST",
      url: "https://api.example.com/v1/messages?source=snapo",
      requestHeaders: [{ name: "X-Trace-Id", value: "trace-123" }],
      responseHeaders: [{ name: "Content-Type", value: "text/event-stream" }],
      status: { kind: "success", code: 202 },
      streamEvents: [
        {
          sequence: 1,
          timestamp: 2,
          eventName: "completion",
          lastEventId: "event-42",
          data: "retained-stream-payload",
          raw: "data: retained-stream-payload"
        }
      ],
      streamEventCount: 1
    });

    for (const searchText of [
      "POST",
      "source=snapo",
      "X-Trace-Id: trace-123",
      "202",
      "completion",
      "event-42",
      "retained-stream-payload"
    ]) {
      expect(matchesNetworkSearch(record, parseNetworkSearchQuery(searchText))).toBe(true);
    }
  });

  it("searches retained WebSocket message and lifecycle data", () => {
    const record = webSocket({
      messages: [
        {
          id: "message-1",
          direction: "incoming",
          opcode: "text",
          preview: "retained-websocket-payload",
          payloadSize: 2_048,
          timestamp: 2,
          enqueued: true
        }
      ],
      messageCount: 1,
      closed: { timestamp: 3, code: 1000, reason: "normal-shutdown" }
    });

    for (const searchText of ["retained-websocket-payload", "2 KB", "enqueued", "1000", "normal-shutdown"]) {
      expect(matchesNetworkSearch(record, parseNetworkSearchQuery(searchText))).toBe(true);
    }
  });
});

const server = { deviceId: "device", socketName: "socket", instanceId: "instance" };

function request(overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    server,
    requestId: "request",
    method: "GET",
    url: "https://example.com/request",
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "pending" },
    startedAt: 1,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 1,
    ...overrides
  };
}

function webSocket(overrides: Partial<WebSocketRecord> = {}): InspectorRecord {
  return {
    kind: "websocket",
    server,
    socketId: "socket",
    method: "WS",
    url: "wss://example.com/socket",
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "success", code: 101 },
    startedAt: 1,
    messages: [],
    messageCount: 0,
    updatedAt: 1,
    ...overrides
  };
}
