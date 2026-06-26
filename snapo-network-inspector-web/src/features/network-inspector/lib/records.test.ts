import { describe, expect, it } from "vitest";
import type { RequestRecord } from "../../../network/cdp";
import { shouldRequestRequestBody } from "./records";

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
