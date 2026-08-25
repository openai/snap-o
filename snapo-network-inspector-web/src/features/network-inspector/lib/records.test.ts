import { describe, expect, it, vi } from "vitest";
import type { RequestRecord, WebSocketRecord } from "../../../network/cdp";
import {
  countExcludedRecordsForServer,
  filterRecords,
  responseBodyCaptureMetadata,
  shouldRequestRequestBody,
  shouldRequestResponseBody
} from "./records";

describe("persistent exclusion filters", () => {
  it("hides requests with Snap-O's regular minus-prefixed filter syntax", () => {
    const hidden = request({ requestId: "hidden", url: "https://events.example.com/track" });
    const visible = request({ requestId: "visible", url: "https://api.openai.com/conversation" });

    expect(filterRecords([hidden, visible], server, "", false, ["-example.com"])).toEqual([visible]);
  });

  it("hides WebSocket connections to excluded hosts", () => {
    const hidden: WebSocketRecord = {
      kind: "websocket",
      server,
      socketId: "hidden-socket",
      method: "GET",
      url: "wss://stream.example.com/live",
      requestHeaders: [],
      responseHeaders: [],
      status: { kind: "pending" },
      startedAt: 1,
      messages: [],
      messageCount: 0,
      updatedAt: 1
    };
    const visible = request({ requestId: "visible", url: "https://api.openai.com/conversation" });

    expect(filterRecords([hidden, visible], server, "", false, ["-example.com"])).toEqual([visible]);
  });

  it("continues applying keyword filters to hosts that are not hidden", () => {
    const hidden = request({ requestId: "hidden", url: "https://events.example.com/conversation" });
    const matching = request({ requestId: "matching", url: "https://api.openai.com/conversation" });
    const unrelated = request({ requestId: "unrelated", url: "https://api.openai.com/models" });

    expect(filterRecords([hidden, matching, unrelated], server, "conversation", false, ["-example.com"])).toEqual([
      matching
    ]);
  });

  it.each([
    { syntax: "an unfinished quote", searchText: '-"noise' },
    { syntax: "a trailing backslash", searchText: "-noise\\" },
    { syntax: "a completed quote", searchText: '-"noise"' },
    { syntax: "an escaped backslash", searchText: "-noise\\\\" }
  ])("applies saved exclusions and search filters with $syntax", ({ searchText }) => {
    const hidden = request({ requestId: "hidden", url: "https://events.example.com/track" });
    const searchHidden = request({
      requestId: "search-hidden",
      url: "https://api.example.com/messages",
      requestHeaders: [{ name: "X-Label", value: "noise\\" }]
    });
    const visible = request({ requestId: "visible", url: "https://api.example.com/messages" });
    const records = [hidden, searchHidden, visible];
    const exclusionFilters = ["-events.example.com"];

    expect(countExcludedRecordsForServer(records, server, exclusionFilters)).toBe(1);
    expect(filterRecords(records, server, searchText, false, exclusionFilters)).toEqual([visible]);
  });

  it("traverses stream events once when search and exclusions are empty", () => {
    const visible = request();
    const iterateEvents = vi.spyOn(visible.streamEvents, Symbol.iterator);

    expect(filterRecords([visible], server, "", false)).toEqual([visible]);
    expect(iterateEvents).toHaveBeenCalledTimes(1);
  });

  it("applies generic exclusion filters to the same searchable metadata as ordinary filters", () => {
    const hidden = request({ requestId: "hidden", method: "POST", url: "https://api.openai.com/messages" });
    const visible = request({ requestId: "visible", method: "GET", url: "https://api.openai.com/messages" });

    expect(filterRecords([hidden, visible], server, "", false, ["-post"])).toEqual([visible]);
  });

  it("counts only excluded requests belonging to the selected server", () => {
    const hidden = request({ requestId: "hidden", url: "https://events.example.com/track" });
    const visible = request({ requestId: "visible", url: "https://api.openai.com/conversation" });
    const anotherServer = request({
      requestId: "another-server",
      server: { deviceId: "another-device", socketName: "socket", instanceId: "instance" },
      url: "https://events.example.com/track"
    });

    expect(countExcludedRecordsForServer([hidden, visible, anotherServer], server, ["-example.com"])).toBe(1);
  });
});

describe("request body loading", () => {
  it("waits until request transmission has completed", () => {
    expect(shouldRequestRequestBody(request())).toBe(false);
    expect(shouldRequestRequestBody(request({ hasReceivedResponse: true }))).toBe(true);
    expect(shouldRequestRequestBody(request({ status: { kind: "failure", message: "failed" } }))).toBe(true);
  });

  it("skips requests without a fetchable body", () => {
    expect(shouldRequestRequestBody(request({ requestHasPostData: false, hasReceivedResponse: true }))).toBe(false);
    expect(shouldRequestRequestBody(request({ requestBodySize: 0, hasReceivedResponse: true }))).toBe(false);
    expect(shouldRequestRequestBody(request({ requestBody: "cached", hasReceivedResponse: true }))).toBe(false);
  });
});

describe("response body loading", () => {
  it("shows a captured-size label while a completed response body is loading", () => {
    const complete = request({
      status: { kind: "success", code: 200 },
      endedAt: 2,
      encodedDataLength: 7_340_032
    });

    expect(shouldRequestResponseBody(complete)).toBe(true);
    expect(responseBodyCaptureMetadata(complete)).toBe("Captured 7.3 MB");
  });

  it("shows the captured prefix and total size for a truncated response", () => {
    const truncated = request({
      status: { kind: "success", code: 200 },
      endedAt: 2,
      encodedDataLength: 9_437_184,
      responseBodyTruncatedBytes: 4_194_304
    });

    expect(shouldRequestResponseBody(truncated)).toBe(true);
    expect(responseBodyCaptureMetadata(truncated)).toBe("Captured 5.2 MB of 9.4 MB");
  });

  it("stops requesting a response body after an unavailable body finishes loading", () => {
    expect(
      shouldRequestResponseBody(
        request({ status: { kind: "success", code: 200 }, endedAt: 2, responseBodyLoadCompleted: true })
      )
    ).toBe(false);
  });
});

const server = { deviceId: "device", socketName: "socket", instanceId: "instance" };

function request(overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    server,
    requestId: "request",
    method: "POST",
    url: "https://example.com/request",
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "pending" },
    startedAt: 1,
    requestHasPostData: true,
    requestBodySize: 8,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 1,
    ...overrides
  };
}
