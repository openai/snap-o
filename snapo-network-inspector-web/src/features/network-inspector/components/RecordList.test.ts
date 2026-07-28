import { describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestRecord, WebSocketRecord } from "../../../network/cdp";
import { sidebarContextMenuItems } from "./RecordList";

describe("network request host filter context menu", () => {
  const client = {
    copyText: vi.fn()
  } as unknown as NetworkClient;

  it("adds a request host to the persistent filtered hosts list", () => {
    const record = request("https://API.Example.COM:443/events");
    const addHiddenHost = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addHiddenHost);
    const item = items.find((entry) => entry.label === "Add to filtered hosts");

    expect(item?.disabled).toBe(false);
    item?.action();

    expect(addHiddenHost).toHaveBeenCalledOnce();
    expect(addHiddenHost).toHaveBeenCalledWith("api.example.com");
  });

  it("adds a WebSocket host to the same persistent filtered hosts list", () => {
    const record = webSocket("wss://stream.example.com/live");
    const addHiddenHost = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addHiddenHost);
    const item = items.find((entry) => entry.label === "Add to filtered hosts");

    expect(item?.disabled).toBe(false);
    item?.action();

    expect(addHiddenHost).toHaveBeenCalledWith("stream.example.com");
  });

  it("disables host filtering for records without a valid host", () => {
    const record = request("Request unfinished");
    const addHiddenHost = vi.fn();

    const items = sidebarContextMenuItems(record, null, [record], client, addHiddenHost);
    const item = items.find((entry) => entry.label === "Add to filtered hosts");

    expect(item?.disabled).toBe(true);
    item?.action();

    expect(addHiddenHost).not.toHaveBeenCalled();
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
