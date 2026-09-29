import { request } from "./body-test-fixtures";
import { describe, expect, it } from "vitest";
import { decodeRequestBody } from "./body-decoding";
import { decodeRequestBodyForDisplay } from "./payload";
import { searchLocalBodies, mergeBodyMatches } from "./body-search";
import { createEmptyToolState, reduceCdpMessage, requestRecordKey } from "./cdp";
import { filterRecords } from "../features/network-tool/lib/records";

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
  it.each(["gzip", "x-gzip", " X-GZip ; level=1", "identity, x-gzip", "identity\nx-gzip"])(
    "uses the same decoding for display and search: %s",
    async (encoding) => {
      const body = await gzip("needle");
      const request = record(body, "base64", encoding);
      const input = { body, encoding: "base64", headers: request.requestHeaders };
      expect(await decodeRequestBodyForDisplay(input)).toBe("needle");
      const matches = await searchLocalBodies(request, ["needle"], signal());
      expect(matches.request).toMatchObject({ terms: ["needle"], complete: true });
    }
  );

  it.each(["ISO-8859-1", '"ISO-8859-1"'])("uses the declared gzip charset: %s", async (charset) => {
    const body = await gzip(new Uint8Array([99, 97, 102, 233]));
    const request = record(body, "base64", "gzip");
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
    const state = reduceCdpMessage(
      createEmptyToolState(),
      "process",
      {
        method: "Network.requestWillBeSent",
        snapoSequence: 1,
        params: {
          requestId: "one",
          request: {
            method: "POST",
            url: "https://example.test/",
            headers: { "Content-Type": "text/plain; charset=iso-8859-1" },
            hasPostData: true,
            postDataLength: 10,
            postDataTruncatedBytes: truncatedBytes
          }
        }
      },
      1
    );
    const request = {
      ...state.requests.values().next().value!,
      requestBody: "é".repeat(6),
      status: { kind: "success" as const, code: 204 }
    };
    expect(request.requestBodyTruncatedBytes).toBe(truncatedBytes ?? null);
    const local = await searchLocalBodies(request, ["missing"], signal());
    expect(local.request.complete).toBe(truncatedBytes === 0);
    const merged = mergeBodyMatches(local, {
      requestId: "one",
      request: { terms: [], complete: false },
      response: { terms: [], complete: true }
    });
    expect(
      filterRecords([request], "-missing", false, [], new Map([[requestRecordKey("process", "one"), merged]]))
    ).toHaveLength(truncatedBytes === 0 ? 1 : 0);
  });
});
