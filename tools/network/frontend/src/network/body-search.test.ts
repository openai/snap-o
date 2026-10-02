import { BodySearchHttpError, type BodySearchQuery, type BodySearchReply } from "./remote-body-search";
import { bodyMatch, request } from "./body-test-fixtures";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { NetworkConnection } from "./connection";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "./client";
import { requestRecordKey, type RequestRecord } from "./cdp";
import { createBodySearch, type BodySearchMatches } from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";
import * as decoding from "./body-decoding";

const connection = { processIdentity: "current", signal: new AbortController().signal } as ToolConnection;
let search: ReturnType<typeof createBodySearch>;
let matches: BodySearchMatches;
const publish = vi.fn((value: BodySearchMatches) => {
  matches = value;
});
beforeEach(() => {
  vi.useFakeTimers();
  publish.mockClear();
});
afterEach(async () => {
  search?.dispose();
  await vi.runAllTimersAsync();
  vi.useRealTimers();
  vi.restoreAllMocks();
});
function start(records: RequestRecord[], searchBodies?: NetworkClient["searchBodies"], terms = ["needle"]) {
  search?.dispose();
  matches = new Map();
  search = createBodySearch({ terms, client: { searchBodies } as NetworkClient, connection, onResults: publish });
  search.update(records);
}

it.each([429, 503, new TypeError("network"), new DOMException("timeout", "TimeoutError")])(
  "retries temporary failure %s without losing local matches",
  async (failure) => {
    const records = [request("old", { responseBody: "needle" }), request()];
    const searchBodies = vi
      .fn()
      .mockRejectedValueOnce(typeof failure === "number" ? new BodySearchHttpError(failure) : failure)
      .mockResolvedValue({ results: [bodyMatch()] });
    start(records, searchBodies);
    await vi.runAllTimersAsync();
    expect(filterRecords(records, "needle", false, [], matches)).toHaveLength(2);
    expect(searchBodies).toHaveBeenCalledTimes(2);
  }
);

it("stops at one unsupported request across batches and query changes", async () => {
  const fetch = vi.fn(async () => new Response(null, { status: 404 }));
  const network = new NetworkConnection(
    connection,
    () => {},
    () => {},
    { fetch, eventSource: vi.fn() }
  );
  const records = [
    request("old", { responseBody: "needle other" }),
    ...Array.from({ length: 9 }, (_, i) =>
      request("current", { requestId: String(i), responseBody: i === 0 ? "needle other" : undefined })
    )
  ];
  for (const term of ["needle", "other"]) {
    start(records, network.searchBodies.bind(network), [term]);
    await vi.runAllTimersAsync();
    expect(filterRecords(records, term, false, [], matches)).toHaveLength(2);
  }
  expect(fetch).toHaveBeenCalledTimes(1);
});

it.each(["replace", "remove", "dispose"])("ignores a delayed Android reply after %s", async (action) => {
  let reply!: (value: BodySearchReply) => void;
  const pending = new Promise<BodySearchReply>((resolve) => {
    reply = resolve;
  });
  const searchBodies = vi.fn().mockReturnValueOnce(pending).mockResolvedValue({ results: [] });
  start([request()], searchBodies, ["needle", "replacement"]);
  await vi.runAllTimersAsync();
  if (action === "dispose") search.dispose();
  else search.update(action === "remove" ? [] : [request("current", { responseBody: "replacement" })]);
  const published = publish.mock.calls.length;
  reply({ results: [bodyMatch()] });
  await vi.runAllTimersAsync();
  if (action === "replace") {
    expect(matches.get(requestRecordKey("current", "same-id"))?.response.terms).toEqual(["replacement"]);
    expect(searchBodies).toHaveBeenCalledTimes(2);
  } else if (action === "remove") expect(matches.size).toBe(0);
  else expect(publish).toHaveBeenCalledTimes(published);
});

it("keeps local searches running and ignores results for old bodies", async () => {
  let decoded!: (value: decoding.DecodedBody) => void;
  const decode = vi.spyOn(decoding, "decodeRequestBody").mockReturnValueOnce(
    new Promise((resolve) => {
      decoded = resolve;
    })
  );
  const original = request("old", {
    requestBody: "old body",
    requestHeaders: [{ name: "Content-Type", value: "text/plain" }]
  });
  start([original]);
  search.update([
    {
      ...original,
      updatedAt: 3,
      streamEventCount: 1,
      status: { kind: "pending" },
      requestHeaders: [
        { name: "content-type", value: "text/plain" },
        { name: "X-Unrelated", value: "new" }
      ]
    }
  ]);
  expect(decode).toHaveBeenCalledTimes(1);
  expect(decode.mock.calls[0][1]?.aborted).toBe(false);
  search.update([{ ...original, requestBody: "replacement" }]);
  decoded({ kind: "text", text: "needle" });
  await vi.runAllTimersAsync();
  expect(matches.get(requestRecordKey("old", "same-id"))?.request.terms).toEqual([]);
  expect(decode).toHaveBeenCalledTimes(2);
  search.update([original, request("old", { requestId: "new", responseBody: "needle" })]);
  await vi.runAllTimersAsync();
  expect(matches.get(requestRecordKey("old", "new"))?.response.terms).toEqual(["needle"]);
});

it.each(["body updates", "temporary failures"])("gives waiting requests a turn during %s", async (change) => {
  let records = Array.from({ length: 9 }, (_, i) => request("current", { requestId: String(i) }));
  const batches: string[][] = [];
  start(records, async (query: BodySearchQuery) => {
    batches.push(query.requestIds);
    if (query.requestIds.includes("8") || batches.length === 3) search.dispose();
    if (change === "temporary failures") throw new TypeError("network");
    records = records.map((record, i) =>
      i < 8 ? { ...record, requestBodySize: (record.requestBodySize ?? 0) + 1 } : record
    );
    search.update(records);
    return { results: [] };
  });
  await vi.runAllTimersAsync();
  expect(batches[0]).toHaveLength(8);
  expect(batches[1]).toContain("8");
});
