import { describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestRecord, WebSocketRecord } from "../../../network/cdp";
import { sidebarContextMenuItems } from "./RecordList";

describe("network request exclusion filter context menu", () => {
  const client = {
    copyText: vi.fn()
  } as unknown as NetworkClient;

  it("adds a request host as a persistent conventional exclusion filter", () => {
    const record = request("https://API.Example.COM:443/events");
    const addExclusionFilter = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addExclusionFilter);
    const item = items.find((entry) => entry.label === "Add host to exclusion filter");

    expect(item?.disabled).toBe(false);
    item?.action();

    expect(addExclusionFilter).toHaveBeenCalledOnce();
    expect(addExclusionFilter).toHaveBeenCalledWith("-api.example.com");
  });

  it("places exclusions after both copy actions and before export", () => {
    const record = request("https://api.example.com/events");

    const items = sidebarContextMenuItems(record, null, [record], client, vi.fn());

    expect(items.map(({ label }) => label)).toEqual([
      "Copy URL",
      "Copy as cURL",
      "Add host to exclusion filter",
      "Export HAR (sanitized)..."
    ]);
  });

  it("adds a WebSocket host to the same persistent exclusion filters", () => {
    const record = webSocket("wss://stream.example.com/live");
    const addExclusionFilter = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addExclusionFilter);
    const item = items.find((entry) => entry.label === "Add host to exclusion filter");

    expect(item?.disabled).toBe(false);
    item?.action();

    expect(addExclusionFilter).toHaveBeenCalledWith("-stream.example.com");
  });

  it("disables host filtering for records without a valid host", () => {
    const record = request("Request unfinished");
    const addExclusionFilter = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addExclusionFilter);
    const item = items.find((entry) => entry.label === "Add host to exclusion filter");

    expect(item?.disabled).toBe(true);
    item?.action();

    expect(addExclusionFilter).not.toHaveBeenCalled();
  });
});

const server = { deviceId: "device", socketName: "socket", instanceId: "instance" };

function request(url: string): RequestRecord {
  return {
    kind: "request",
    server,
    requestId: "request",
    method: "GET",
    url,
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "pending" },
    startedAt: 1,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 1
  };
}

function webSocket(url: string): WebSocketRecord {
  return {
    kind: "websocket",
    server,
    socketId: "socket",
    method: "GET",
    url,
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "pending" },
    startedAt: 1,
    messages: [],
    messageCount: 0,
    updatedAt: 1
  };
}
