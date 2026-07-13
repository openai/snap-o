import { describe, expect, it } from "vitest";
import type { RequestRecord } from "../../../network/cdp";
import { responseBodyCaptureMetadata, shouldRequestRequestBody, shouldRequestResponseBody } from "./records";

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
