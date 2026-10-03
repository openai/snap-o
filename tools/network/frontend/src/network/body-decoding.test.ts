import { request } from "./body-test-fixtures";
import { describe, expect, it } from "vitest";
import { decodeRequestBody } from "./body-decoding";
import { decodeRequestBodyForDisplay } from "./payload";
import { searchLocalBodies } from "./body-search";
import { createEmptyToolState, reduceCdpMessage } from "./cdp";

async function gzip(body: string | Uint8Array): Promise<string> {
  const bytes = typeof body === "string" ? new TextEncoder().encode(body) : new Uint8Array(body);
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream("gzip"));
  const compressed = new Uint8Array(await new Response(stream).arrayBuffer());
  return btoa(String.fromCharCode(...compressed));
}

const signal = () => new AbortController().signal;
function record(body: string, encoding: string, contentEncoding: string) {
  return request("process", {
    requestBody: body,
    requestBodyEncoding: encoding,
    requestHeaders: [{ name: "Content-Encoding", value: contentEncoding }],
    requestBodyTruncatedBytes: 0,
    requestHasPostData: true,
    status: { kind: "success", code: 204 }
  });
}

describe("shared request body decoding", () => {
  it.each([
    ["gzip", "utf-8"],
    ["x-gzip", "ISO-8859-1"],
    [" X-GZip ; level=1", '"ISO-8859-1"'],
    ["identity, x-gzip", "utf-8"],
    ["identity\nx-gzip", "utf-8"]
  ])("display and search decode %s with charset %s", async (encoding, charset) => {
    const body = await gzip(charset === "utf-8" ? "café" : new Uint8Array([99, 97, 102, 233]));
    const request = record(body, "base64", encoding);
    request.requestHeaders.push({ name: "Content-Type", value: `text/plain; charset=${charset}` });
    expect(await decodeRequestBodyForDisplay({ body, encoding: "base64", headers: request.requestHeaders })).toBe(
      "café"
    );
    expect((await searchLocalBodies(request, ["café"], signal())).request).toMatchObject({
      terms: ["café"],
      complete: true
    });
  });

  it("keeps binary display explanations out of searchable text", async () => {
    const body = await gzip(new Uint8Array([0xff, 0xfe]));
    const request = record(body, "base64", "gzip");
    expect(await decodeRequestBodyForDisplay({ body, encoding: "base64", headers: request.requestHeaders })).toContain(
      "Binary payload"
    );
    expect((await searchLocalBodies(request, ["binary"], signal())).request).toEqual({ terms: [], complete: false });
  });

  it("bounds decompression and honors cancellation", async () => {
    const input = {
      body: await gzip("x".repeat(8 * 1024 * 1024 + 1)),
      encoding: "base64",
      headers: [{ name: "Content-Encoding", value: "gzip" }]
    };
    expect(await decodeRequestBody(input)).toEqual({ kind: "unavailable" });
    const abort = new AbortController();
    abort.abort();
    await expect(decodeRequestBody(input, abort.signal)).rejects.toThrow();
  });

  it.each([undefined, 0, 4])("uses capture metadata instead of UTF-8 length: %s", async (truncatedBytes) => {
    const state = reduceCdpMessage(createEmptyToolState(), "process", {
      method: "Network.requestWillBeSent",
      snapoSequence: 1,
      params: {
        requestId: "one",
        request: {
          method: "POST",
          url: "https://example.test/",
          hasPostData: true,
          postDataLength: 10,
          postDataTruncatedBytes: truncatedBytes
        }
      }
    });
    const record = { ...state.requests.values().next().value!, requestBody: "é".repeat(6) };
    expect(record.requestBodyTruncatedBytes).toBe(truncatedBytes ?? null);
    const match = await searchLocalBodies(record, ["missing"], signal());
    expect(match.request.complete).toBe(truncatedBytes === 0);
  });
});
