import { request } from "./body-test-fixtures";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ToolConnection } from "@snap-o/tool-host";
import type { ToolRecord } from "./cdp";
import { requestRecordKey } from "./cdp";
import type { NetworkClient } from "./client";
import {
  BodySearchHttpError,
  mergeBodyMatches,
  searchBodyText,
  searchCaptureBodies,
  searchLocalBodies,
  type BodySearchCache,
  type BodySearchMatches,
  type BodySearchReply
} from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";

const connection = { processIdentity: "current", signal: new AbortController().signal } as ToolConnection;

const signal = () => new AbortController().signal;
const reply = (terms: string[]): BodySearchReply => ({
  results: [
    {
      requestId: "same-id",
      request: { terms: [], complete: true },
      response: { terms, complete: true }
    }
  ]
});
function search(
  records: ToolRecord[],
  searchBodies: NetworkClient["searchBodies"],
  options: {
    terms?: string[];
    signal?: AbortSignal;
    publish?: (matches: BodySearchMatches) => void;
    cache?: BodySearchCache;
  } = {}
) {
  return searchCaptureBodies(
    records,
    options.terms ?? ["needle"],
    { searchBodies } as NetworkClient,
    connection,
    options.signal ?? signal(),
    options.publish ?? (() => {}),
    options.cache
  );
}

afterEach(() => vi.useRealTimers());

describe("body search", () => {
  it.each([
    new BodySearchHttpError(429),
    new BodySearchHttpError(503),
    new TypeError("Network request failed"),
    new DOMException("Request timed out", "TimeoutError")
  ])("retries the same batch after a temporary failure: %s", async (error) => {
    vi.useFakeTimers();
    const record = request();
    const searchBodies = vi
      .fn()
      .mockRejectedValueOnce(error)
      .mockResolvedValue(reply(["needle"]));
    const publish = vi.fn();
    const pending = search([record], searchBodies, { publish });
    await vi.advanceTimersByTimeAsync(0);
    expect(searchBodies).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(500);
    const matches = await pending;
    expect(searchBodies).toHaveBeenCalledTimes(2);
    expect(searchBodies.mock.calls[1]).toEqual(searchBodies.mock.calls[0]);
    expect(filterRecords([record], "needle", false, [], matches)).toEqual([record]);
    expect(filterRecords([record], "needle", false, [], publish.mock.lastCall![0])).toEqual([record]);
  });

  it("stops retrying when the query is canceled", async () => {
    vi.useFakeTimers();
    const abort = new AbortController();
    const searchBodies = vi.fn().mockRejectedValue(new BodySearchHttpError(429));
    const pending = search([request()], searchBodies, { signal: abort.signal });
    const rejected = expect(pending).rejects.toThrow();
    await vi.advanceTimersByTimeAsync(0);
    abort.abort();
    await vi.advanceTimersByTimeAsync(500);
    await rejected;
    expect(searchBodies).toHaveBeenCalledTimes(1);
  });

  it.each([400, 404])("does not retry HTTP %i", async (status) => {
    const searchBodies = vi.fn().mockRejectedValue(new BodySearchHttpError(status));
    await search([request()], searchBodies);
    expect(searchBodies).toHaveBeenCalledTimes(1);
  });

  it("finds a phrase across chunks and can cancel a long search", async () => {
    const text = "x".repeat(16_380) + "hello world";
    expect((await searchBodyText(text, ["hello world"], signal())).terms).toEqual(["hello world"]);
    const abort = new AbortController();
    const pending = searchBodyText("x".repeat(1_000_000), ["missing"], abort.signal);
    abort.abort();
    await expect(pending).rejects.toThrow();
  });

  it("combines matches from metadata, older cached bodies, and Android bodies", async () => {
    const old = request("previous", { responseBody: "archived needle" });
    const current = request("current", { requestBody: "client", requestHasPostData: true, requestBodySize: 6 });
    const searchBodies = vi.fn(async () => reply(["server"]));
    const result = await search([old, current], searchBodies, { terms: ["archived", "client", "server"] });
    expect(searchBodies.mock.calls).toHaveLength(1);
    expect(filterRecords([old, current], "archived", false, [], result)).toEqual([old]);
    expect(filterRecords([old, current], "orders client server", false, [], result)).toEqual([current]);
    expect(result.get(requestRecordKey("previous", "same-id"))!.response.terms).toEqual(["archived"]);
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

  it("preserves cached results if Android lacks body search", async () => {
    const record = request("previous", { responseBody: "needle" });
    const current = request();
    const searchBodies = vi.fn().mockRejectedValue(new BodySearchHttpError(404));
    const result = await search([record, current], searchBodies);
    expect(filterRecords([record, current], "needle", false, [], result)).toEqual([record]);
  });

  it("ignores late Android results after the search is canceled", async () => {
    const abort = new AbortController();
    const publish = vi.fn();
    const searchBodies = vi.fn(async (): Promise<BodySearchReply> => {
      abort.abort();
      return { results: [] };
    });
    await expect(search([request()], searchBodies, { signal: abort.signal, publish })).rejects.toThrow();
    expect(publish).toHaveBeenCalledTimes(1);
  });

  it("reuses unchanged captures and searches again when a body changes", async () => {
    const record = request();
    const searchBodies = vi.fn(async () => reply(["needle"]));
    const cache: BodySearchCache = new Map();
    await search([record], searchBodies, { cache });
    const publish = vi.fn();
    await search([{ ...record }], searchBodies, { publish, cache });
    expect(searchBodies).toHaveBeenCalledTimes(1);
    expect(publish.mock.calls[0][0].get(requestRecordKey("current", record.requestId)).response.terms).toEqual([
      "needle"
    ]);
    await search([{ ...record, responseBody: "needle updated" }], searchBodies, { cache });
    expect(searchBodies).toHaveBeenCalledTimes(2);
    await search([], searchBodies, { cache });
    expect(cache.size).toBe(0);
  });

  it("marks cut-off response bodies as partially searched", async () => {
    const record = request("current", { responseBody: "needle", responseBodyTruncatedBytes: 100 });
    const result = await searchLocalBodies(record, ["needle"], signal());
    expect(result.response.terms).toEqual(["needle"]);
    expect(result.response.complete).toBe(false);
  });
});
