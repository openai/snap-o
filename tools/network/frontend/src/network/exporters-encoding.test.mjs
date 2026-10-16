import assert from "node:assert/strict";
import { describe, it } from "vitest";
import { buildHar } from "./exporters";

const text = "abcdefghijklmnop";
function record(overrides = {}) {
  return {
    kind: "request", processId: "fixture", requestId: "request",
    method: "GET", url: "https://example.com/fixture", requestHeaders: [],
    responseHeaders: [{ name: "Content-Type", value: "application/octet-stream" }],
    status: { kind: "success", code: 200 }, startedAt: 1, updatedAt: 2, endedAt: 2,
    streamEvents: [], streamEventCount: 0, responseBody: text,
    ...overrides
  };
}
function exported(overrides) {
  return JSON.parse(buildHar([record(overrides)], "fixture")).log.entries[0].response;
}
function bytes(content) {
  return content.encoding === "base64"
    ? Buffer.from(content.text, "base64")
    : Buffer.from(content.text, "utf8");
}

describe("HAR response encoding metadata", () => {
  for (const mime of ["application/octet-stream", "image/png", "application/x-custom", undefined]) {
    it(`keeps explicitly unencoded ${mime ?? "unknown"} content as text`, () => {
      const responseHeaders = mime ? [{ name: "Content-Type", value: mime }] : [];
      const response = exported({ responseHeaders, responseBodyBase64Encoded: false });
      assert.equal(response.content.encoding, undefined);
      assert.equal(response.content.text, text);
      assert.equal(response.content.size, Buffer.byteLength(text));
      assert.deepEqual(bytes(response.content), Buffer.from(text));
    });
  }

  for (const mime of ["text/plain", "application/json", "application/octet-stream"]) {
    it(`honors explicit base64 with ${mime}`, () => {
      const raw = Buffer.from([0, 1, 255, 65]);
      const response = exported({
        responseBody: raw.toString("base64"), responseBodyBase64Encoded: true,
        responseHeaders: [{ name: "Content-Type", value: mime }]
      });
      assert.equal(response.content.encoding, "base64");
      assert.deepEqual(bytes(response.content), raw);
      assert.equal(response.content.size, raw.length);
    });
  }

  for (const metadata of [undefined, null]) {
    it(`preserves legacy guessing when the flag is ${metadata}`, () => {
      const response = exported({ responseBodyBase64Encoded: metadata });
      assert.equal(response.content.encoding, "base64");
      assert.deepEqual(bytes(response.content), Buffer.from(text, "base64"));
    });
  }

  it("retains the text MIME fallback when encoding metadata is missing", () => {
    const response = exported({ responseHeaders: [{ name: "Content-Type", value: "text/plain" }] });
    assert.equal(response.content.encoding, undefined);
    assert.deepEqual(bytes(response.content), Buffer.from(text));
  });

  it("preserves an explicitly unencoded empty body", () => {
    const response = exported({ responseBody: "", responseBodyBase64Encoded: false });
    assert.equal(response.content.encoding, undefined);
    assert.equal(response.content.text, "");
    assert.equal(response.content.size, 0);
  });

  it("does not label an absent body as encoded", () => {
    const response = exported({ responseBody: null, responseBodyBase64Encoded: true });
    assert.equal(response.content.encoding, undefined);
    assert.equal(response.content.text, undefined);
  });

  it("retains stream-event text rather than applying a response encoding flag", () => {
    const response = exported({
      responseBody: null, responseBodyBase64Encoded: true,
      streamEvents: [{ raw: "data: synthetic\n\n" }], streamEventCount: 1
    });
    assert.equal(response.content.encoding, undefined);
    assert.equal(response.content.text, "data: synthetic\n\n");
  });

  it("does not change headers, redaction or other response metadata", () => {
    const original = record({ responseBodyBase64Encoded: false });
    original.requestHeaders = [{ name: "Authorization", value: "synthetic" }];
    original.responseHeaders.push({ name: "Set-Cookie", value: "synthetic" });
    const before = structuredClone(original);
    const entry = JSON.parse(buildHar([original], "fixture")).log.entries[0];
    assert.deepEqual(original, before);
    assert.deepEqual(entry.request.headers, []);
    assert.equal(entry.response.headers.length, 1);
    assert.equal(entry.response.status, 200);
  });
});
