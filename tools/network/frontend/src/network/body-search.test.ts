import { BodySearchHttpError, type BodySearchQuery } from "./remote-body-search";
import { request } from "./body-test-fixtures";
import { expect, it, vi } from "vitest";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "./client";
import { requestRecordKey } from "./cdp";
import {
  mergeBodyMatches,
  searchBodyText,
  searchLocalBodies,
  searchLocalCapture,
  searchAndroidCapture,
  bodySearchMatches,
  type BodySearchCache
} from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";

const connection = { processIdentity: "current" } as ToolConnection;
const signal = () => new AbortController().signal;

it("finds a phrase across chunks and can cancel a long search", async () => {
  const text = "x".repeat(16_380) + "hello world";
  expect((await searchBodyText(text, ["hello world"], signal())).terms).toEqual(["hello world"]);
  const abort = new AbortController();
  const pending = searchBodyText("x".repeat(1_000_000), ["missing"], abort.signal);
  abort.abort();
  await expect(pending).rejects.toThrow();
});

it("checks exclusions in both sources and treats missing bodies as unknown", async () => {
  const record = request("current", { responseBody: "wanted forbidden" });
  const local = await searchLocalBodies(record, ["wanted", "forbidden"], signal());
  const remote = {
    requestId: record.requestId,
    request: { terms: [], complete: true },
    response: { terms: ["wanted"], complete: true }
  };
  const matches = new Map([[requestRecordKey(record.processId, record.requestId), mergeBodyMatches(local, remote)]]);
  expect(filterRecords([record], "wanted -forbidden", false, [], matches)).toEqual([]);
  matches.set(requestRecordKey(record.processId, record.requestId), {
    ...remote,
    response: { terms: ["wanted"], complete: false }
  });
  expect(filterRecords([record], "wanted -missing", false, [], matches)).toEqual([]);
  expect(filterRecords([record], "wanted", false, [], matches)).toEqual([record]);
});

it.each([429, 503, new TypeError("network"), new DOMException("timeout", "TimeoutError"), 404])(
  "handles Android failure %s without losing local matches",
  async (failure) => {
    const cache: BodySearchCache = new Map();
    const abort = new AbortController();
    const records = [request("old", { responseBody: "needle" }), request()];
    const publish = vi.fn();
    await searchLocalCapture(records, ["needle"], abort.signal, cache, publish);
    const searchBodies = vi
      .fn()
      .mockRejectedValueOnce(typeof failure === "number" ? new BodySearchHttpError(failure) : failure)
      .mockResolvedValue({
        results: [
          {
            requestId: "same-id",
            request: { terms: [], complete: true },
            response: { terms: ["needle"], complete: true }
          }
        ]
      });
    const pending = searchAndroidCapture(
      ["needle"],
      { searchBodies } as unknown as NetworkClient,
      connection,
      abort.signal,
      cache,
      publish
    );
    const stopped = expect(pending).rejects.toThrow();
    try {
      await vi.waitFor(() =>
        expect(filterRecords(records, "needle", false, [], bodySearchMatches(cache))).toHaveLength(
          failure === 404 ? 1 : 2
        )
      );
      expect(searchBodies).toHaveBeenCalledTimes(failure === 404 ? 1 : 2);
    } finally {
      abort.abort();
      await stopped;
    }
  }
);

it("ignores old replies after a body changes or its row is removed", async () => {
  const cache: BodySearchCache = new Map();
  const abort = new AbortController();
  const publish = vi.fn();
  const original = request();
  await searchLocalCapture([original], ["needle"], abort.signal, cache, publish);
  let reply!: (value: { results: [] }) => void;
  const searchBodies = vi.fn(
    () =>
      new Promise<{ results: [] }>((resolve) => {
        reply = resolve;
      })
  );
  const pending = searchAndroidCapture(
    ["needle"],
    { searchBodies } as unknown as NetworkClient,
    connection,
    abort.signal,
    cache,
    publish
  );
  const stopped = expect(pending).rejects.toThrow();
  try {
    await searchLocalCapture([{ ...original, responseBody: "needle" }], ["needle"], abort.signal, cache, publish);
    reply({ results: [] });
    await vi.waitFor(() => expect(searchBodies).toHaveBeenCalledTimes(2));
    expect(bodySearchMatches(cache).get(requestRecordKey("current", "same-id"))?.response.terms).toEqual(["needle"]);
    await searchLocalCapture([], ["needle"], abort.signal, cache, publish);
    abort.abort();
    reply({ results: [] });
    await stopped;
    expect(cache.size).toBe(0);
  } finally {
    abort.abort();
    reply({ results: [] });
  }
});

it("keeps completed matches through repeated metadata updates", async () => {
  const cache: BodySearchCache = new Map();
  const abort = new AbortController();
  let records = Array.from({ length: 17 }, (_, i) =>
    request("current", {
      requestId: String(i),
      endedAt: undefined,
      hasReceivedResponse: true,
      requestHeaders: [{ name: "Content-Type", value: "text/plain" }]
    })
  );
  const publish = vi.fn();
  const searchBodies = vi.fn(async (query: BodySearchQuery) => ({
    results: query.requestIds.map((requestId) => ({
      requestId,
      request: { terms: [], complete: true },
      response: { terms: ["needle"], complete: false }
    }))
  }));
  await searchLocalCapture(records, ["needle"], abort.signal, cache, publish);
  const pending = searchAndroidCapture(
    ["needle"],
    { searchBodies } as unknown as NetworkClient,
    connection,
    abort.signal,
    cache,
    publish
  );
  const stopped = expect(pending).rejects.toThrow();
  try {
    await vi.waitFor(() => expect(searchBodies).toHaveBeenCalledTimes(3));
    for (let update = 0; update < 3; update++) {
      records = records.map((record) => ({
        ...record,
        updatedAt: record.updatedAt + 1,
        streamEventCount: record.streamEventCount + 1,
        status: { kind: "pending" },
        requestHeaders: [
          { name: "content-type", value: "text/plain" },
          { name: "X-Unrelated", value: String(update) }
        ]
      }));
      await searchLocalCapture(records, ["needle"], abort.signal, cache, publish);
      expect(filterRecords(records, "needle", false, [], bodySearchMatches(cache))).toHaveLength(17);
      expect([...cache.values()].every((entry) => entry.remote)).toBe(true);
    }
    expect(searchBodies).toHaveBeenCalledTimes(3);
  } finally {
    abort.abort();
    await stopped;
  }
});

it.each(["body updates", "temporary failures"])("gives waiting requests a turn during %s", async (change) => {
  const cache: BodySearchCache = new Map();
  const abort = new AbortController();
  let records = Array.from({ length: 9 }, (_, i) => request("current", { requestId: String(i) }));
  const publish = () => {};
  const batches: string[][] = [];
  await searchLocalCapture(records, ["needle"], abort.signal, cache, publish);
  const searchBodies = async (query: BodySearchQuery) => {
    batches.push(query.requestIds);
    if (query.requestIds.includes("8") || batches.length === 3) abort.abort();
    abort.signal.throwIfAborted();
    if (change === "temporary failures") throw new TypeError("network");
    records = records.map((record, i) =>
      i < 8 ? { ...record, requestBodySize: (record.requestBodySize ?? 0) + 1 } : record
    );
    await searchLocalCapture(records, ["needle"], abort.signal, cache, publish);
    return { results: [] };
  };
  await expect(
    searchAndroidCapture(
      ["needle"],
      { searchBodies } as unknown as NetworkClient,
      connection,
      abort.signal,
      cache,
      publish
    )
  ).rejects.toThrow();
  expect(batches[0]).toHaveLength(8);
  expect(batches[1]).toContain("8");
});
