import { BodySearchHttpError, type BodySearchQuery } from "./remote-body-search";
import { bodyMatch, request } from "./body-test-fixtures";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { NetworkConnection } from "./connection";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "./client";
import { requestRecordKey, type RequestRecord } from "./cdp";
import { searchLocalCapture, searchAndroidCapture, bodySearchMatches, type BodySearchCache } from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";

const connection = { processIdentity: "current", signal: new AbortController().signal } as ToolConnection;
let cache: BodySearchCache;
let abort: AbortController;
let remote: Promise<unknown> | undefined;
beforeEach(() => {
  cache = new Map();
  abort = new AbortController();
  remote = undefined;
});
afterEach(async () => {
  abort.abort();
  const error = await remote;
  if (error) expect(error).toMatchObject({ name: "AbortError" });
});
const scan = (records: RequestRecord[], terms = ["needle"]) =>
  searchLocalCapture(records, terms, abort.signal, cache, () => {});
const runAndroid = (searchBodies: NetworkClient["searchBodies"], terms = ["needle"]) =>
  (remote = searchAndroidCapture(
    terms,
    { searchBodies } as NetworkClient,
    connection,
    abort.signal,
    cache,
    () => {}
  ).catch((error: unknown) => error));

it.each([429, 503, new TypeError("network"), new DOMException("timeout", "TimeoutError")])(
  "retries temporary failure %s without losing local matches",
  async (failure) => {
    const records = [request("old", { responseBody: "needle" }), request()];
    await scan(records);
    const searchBodies = vi
      .fn()
      .mockRejectedValueOnce(typeof failure === "number" ? new BodySearchHttpError(failure) : failure)
      .mockResolvedValue({ results: [bodyMatch()] });
    void runAndroid(searchBodies);
    await vi.waitFor(() =>
      expect(filterRecords(records, "needle", false, [], bodySearchMatches(cache))).toHaveLength(2)
    );
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
    cache.clear();
    await scan(records, [term]);
    await expect(runAndroid(network.searchBodies.bind(network), [term])).resolves.toBeUndefined();
    expect(filterRecords(records, term, false, [], bodySearchMatches(cache))).toHaveLength(2);
  }
  expect(fetch).toHaveBeenCalledTimes(1);
});

it("ignores old replies after a body changes or its row is removed", async () => {
  const original = request();
  await scan([original]);
  let reply!: (value: { results: [] }) => void;
  const searchBodies = vi.fn(
    () =>
      new Promise<{ results: [] }>((resolve) => {
        reply = resolve;
      })
  );
  void runAndroid(searchBodies);
  try {
    await scan([{ ...original, responseBody: "needle" }]);
    reply({ results: [] });
    await vi.waitFor(() => expect(searchBodies).toHaveBeenCalledTimes(2));
    expect(bodySearchMatches(cache).get(requestRecordKey("current", "same-id"))?.response.terms).toEqual(["needle"]);
    await scan([]);
    abort.abort();
    reply({ results: [] });
    await remote;
    expect(cache.size).toBe(0);
  } finally {
    abort.abort();
    reply({ results: [] });
  }
});

it.each(["body updates", "temporary failures"])("gives waiting requests a turn during %s", async (change) => {
  let records = Array.from({ length: 9 }, (_, i) => request("current", { requestId: String(i) }));
  const batches: string[][] = [];
  await scan(records);
  const searchBodies = async (query: BodySearchQuery) => {
    batches.push(query.requestIds);
    if (query.requestIds.includes("8") || batches.length === 3) abort.abort();
    abort.signal.throwIfAborted();
    if (change === "temporary failures") throw new TypeError("network");
    records = records.map((record, i) =>
      i < 8 ? { ...record, requestBodySize: (record.requestBodySize ?? 0) + 1 } : record
    );
    await scan(records);
    return { results: [] };
  };
  await runAndroid(searchBodies);
  expect(batches[0]).toHaveLength(8);
  expect(batches[1]).toContain("8");
});
