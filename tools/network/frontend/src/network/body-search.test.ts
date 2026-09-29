import { describe, expect, it, vi } from "vitest";
import type { ToolConnection } from "@snap-o/tool-host";
import type { RequestRecord } from "./cdp";
import { requestRecordKey } from "./cdp";
import type { NetworkClient } from "./client";
import {
  mergeBodyMatches,
  searchBodyText,
  searchCaptureBodies,
  searchLocalBodies,
  type BodySearchCache,
  type BodySearchReply
} from "./body-search";
import { filterRecords } from "../features/network-tool/lib/records";

function request(processId = "current", overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    processId,
    requestId: "same-id",
    method: "POST",
    url: "https://example.test/orders",
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "success", code: 200 },
    startedAt: 1,
    endedAt: 2,
    updatedAt: 2,
    streamEvents: [],
    streamEventCount: 0,
    requestHasPostData: false,
    ...overrides
  };
}
const connection = { processIdentity: "current", signal: new AbortController().signal } as ToolConnection;

describe("body search", () => {
  it("finds a phrase across chunks and can cancel a long search", async () => {
    const text = "x".repeat(16_380) + "hello world";
    expect((await searchBodyText(text, ["hello world"], new AbortController().signal)).terms).toEqual(["hello world"]);
    const abort = new AbortController();
    const pending = searchBodyText("x".repeat(1_000_000), ["missing"], abort.signal);
    abort.abort();
    await expect(pending).rejects.toThrow();
  });

  it("combines matches from metadata, older cached bodies, and Android bodies", async () => {
    const old = request("previous", { responseBody: "archived needle" });
    const current = request("current", { requestBody: "client", requestHasPostData: true, requestBodySize: 6 });
    const searchBodies = vi.fn(
      async (): Promise<BodySearchReply> => ({
        results: [
          {
            requestId: "same-id",
            request: { terms: [], complete: true },
            response: { terms: ["server"], complete: true }
          }
        ]
      })
    );
    const result = await searchCaptureBodies(
      [old, current],
      ["archived", "client", "server"],
      { searchBodies } as unknown as NetworkClient,
      connection,
      new AbortController().signal,
      () => {}
    );
    expect(searchBodies.mock.calls).toHaveLength(1);
    expect(filterRecords([old, current], "archived", false, [], result)).toEqual([old]);
    expect(filterRecords([old, current], "orders client server", false, [], result)).toEqual([current]);
    expect(result.get(requestRecordKey("previous", "same-id"))!.response.terms).toEqual(["archived"]);
  });

  it("checks exclusions in both sources and treats missing bodies as unknown", async () => {
    const record = request("current", { responseBody: "wanted forbidden" });
    const local = await searchLocalBodies(record, ["wanted", "forbidden"], new AbortController().signal);
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
    const result = await searchCaptureBodies(
      [record, current],
      ["needle"],
      {
        searchBodies: async () => {
          throw new Error("404");
        }
      } as unknown as NetworkClient,
      connection,
      new AbortController().signal,
      () => {}
    );
    expect(filterRecords([record, current], "needle", false, [], result)).toEqual([record]);
  });

  it("ignores late Android results after the search is canceled", async () => {
    const abort = new AbortController();
    const publish = vi.fn();
    const searchBodies = vi.fn(async (): Promise<BodySearchReply> => {
      abort.abort();
      return { results: [] };
    });
    await expect(
      searchCaptureBodies(
        [request()],
        ["needle"],
        { searchBodies } as unknown as NetworkClient,
        connection,
        abort.signal,
        publish
      )
    ).rejects.toThrow();
    expect(publish).toHaveBeenCalledTimes(1);
  });

  it("reuses unchanged captures and searches again when a body changes", async () => {
    const record = request();
    const searchBodies = vi.fn(
      async (): Promise<BodySearchReply> => ({
        results: [
          {
            requestId: record.requestId,
            request: { terms: [], complete: true },
            response: { terms: ["needle"], complete: true }
          }
        ]
      })
    );
    const client = { searchBodies } as unknown as NetworkClient;
    const cache: BodySearchCache = new Map();
    const signal = new AbortController().signal;
    await searchCaptureBodies([record], ["needle"], client, connection, signal, () => {}, cache);
    const publish = vi.fn();
    await searchCaptureBodies([{ ...record }], ["needle"], client, connection, signal, publish, cache);
    expect(searchBodies).toHaveBeenCalledTimes(1);
    expect(publish.mock.calls[0][0].get(requestRecordKey("current", record.requestId)).response.terms).toEqual([
      "needle"
    ]);
    await searchCaptureBodies(
      [{ ...record, responseBody: "needle updated" }],
      ["needle"],
      client,
      connection,
      signal,
      () => {},
      cache
    );
    expect(searchBodies).toHaveBeenCalledTimes(2);
    await searchCaptureBodies([], ["needle"], client, connection, signal, () => {}, cache);
    expect(cache.size).toBe(0);
  });

  it("marks cut-off response bodies as partially searched", async () => {
    const record = request("current", { responseBody: "needle", responseBodyTruncatedBytes: 100 });
    const result = await searchLocalBodies(record, ["needle"], new AbortController().signal);
    expect(result.response.terms).toEqual(["needle"]);
    expect(result.response.complete).toBe(false);
  });
});
