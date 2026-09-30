import { findTextMatches } from "./text-matcher";
import { responseBodyCoverage, requestBodyCoverage, type BodyCoverage } from "./body-coverage";
import { decodeRequestBody, hasGzipContentEncoding } from "./body-decoding";
import type { RequestRecord, ToolRecord } from "./cdp";
import { requestRecordKey } from "./cdp";
import type { NetworkClient } from "./client";
import type { ToolConnection } from "@snap-o/tool-host";

import {
  BodySearchHttpError,
  bodySearchLimits,
  yieldSearch,
  type BodySearchMatch,
  type RequestBodySearchMatch
} from "./remote-body-search";
export type BodySearchMatches = ReadonlyMap<string, RequestBodySearchMatch>;
export const emptyBodySearchMatches: BodySearchMatches = new Map();

// Overlap text chunks to find phrases that span two chunks.
export async function searchBodyText(
  text: string,
  terms: readonly string[],
  signal: AbortSignal
): Promise<BodySearchMatch> {
  const found = new Set<string>();
  const overlap = Math.max(0, ...terms.map((term) => term.length));
  let snippet: string | undefined;
  await yieldSearch(signal);
  let deadline = performance.now() + 4;
  for (let start = 0; start < text.length; start += 16_384) {
    signal.throwIfAborted();
    if (performance.now() >= deadline) {
      await yieldSearch(signal);
      deadline = performance.now() + 4;
    }
    const chunk = text.slice(start, start + 16_384 + overlap);
    for (const match of findTextMatches(
      chunk,
      terms.filter((term) => !found.has(term)),
      1
    )) {
      found.add(match.term);
      snippet ??= text.slice(Math.max(0, start + match.start - 40), start + match.start + 120);
    }
    if (found.size === terms.length) break;
  }
  return { terms: [...found], complete: true, snippet };
}

export async function searchLocalBodies(
  record: RequestRecord,
  terms: string[],
  signal: AbortSignal
): Promise<RequestBodySearchMatch> {
  const decoded =
    record.requestBody == null
      ? null
      : await decodeRequestBody(
          {
            body: record.requestBody,
            headers: record.requestHeaders,
            encoding: record.requestBodyEncoding
          },
          signal
        );
  const requestText = decoded?.kind === "text" ? decoded.text : null;
  const responseText = record.responseBodyBase64Encoded ? null : record.responseBody;
  const requestCoverage = requestBodyCoverage(record);
  const responseCoverage = responseBodyCoverage(record);
  return {
    requestId: record.requestId,
    request: await searchCoveredBody(requestText, requestCoverage, terms, signal),
    response: await searchCoveredBody(responseText ?? null, responseCoverage, terms, signal)
  };
}

async function searchCoveredBody(
  text: string | null,
  coverage: BodyCoverage,
  terms: string[],
  signal: AbortSignal
): Promise<BodySearchMatch> {
  if (text == null) return { terms: [], complete: coverage === "absent" };
  const match = await searchBodyText(text, terms, signal);
  return { ...match, complete: coverage === "complete" };
}

export function mergeBodyMatches(
  local: RequestBodySearchMatch,
  remote: RequestBodySearchMatch
): RequestBodySearchMatch {
  const merge = (a: BodySearchMatch, b: BodySearchMatch): BodySearchMatch => ({
    terms: [...new Set([...a.terms, ...b.terms])],
    complete: a.complete || b.complete,
    snippet: a.snippet ?? b.snippet
  });
  return {
    requestId: local.requestId,
    request: merge(local.request, remote.request),
    response: merge(local.response, remote.response)
  };
}

interface CachedBodySearch {
  source: RequestRecord;
  local?: RequestBodySearchMatch;
  // Undefined is pending; null is a completed lookup with no result.
  remote?: RequestBodySearchMatch | null;
  previous?: RequestBodySearchMatch;
}

// Reuse results for one query and connection. Remove entries when their records are removed.
export type BodySearchCache = Map<string, CachedBodySearch>;

function sameSearchSource(a: RequestRecord, b: RequestRecord): boolean {
  return (
    a.requestBody === b.requestBody &&
    a.requestBodyEncoding === b.requestBodyEncoding &&
    a.requestBodySize === b.requestBodySize &&
    a.requestBodyTruncatedBytes === b.requestBodyTruncatedBytes &&
    a.requestHasPostData === b.requestHasPostData &&
    hasGzipContentEncoding(a.requestHeaders) === hasGzipContentEncoding(b.requestHeaders) &&
    a.requestHeaders.find((header) => header.name.toLowerCase() === "content-type")?.value ===
      b.requestHeaders.find((header) => header.name.toLowerCase() === "content-type")?.value &&
    a.responseBody === b.responseBody &&
    a.responseBodyBase64Encoded === b.responseBodyBase64Encoded &&
    a.responseBodyTruncatedBytes === b.responseBodyTruncatedBytes &&
    (a.endedAt != null) === (b.endedAt != null) &&
    a.encodedDataLength === b.encodedDataLength &&
    Boolean(a.hasReceivedResponse) === Boolean(b.hasReceivedResponse) &&
    (a.status.kind === "failure") === (b.status.kind === "failure") &&
    responseBodyCoverage(a) === responseBodyCoverage(b)
  );
}

function entryMatch(entry: CachedBodySearch): RequestBodySearchMatch | undefined {
  return entry.local && entry.remote
    ? mergeBodyMatches(entry.local, entry.remote)
    : (entry.local ?? entry.remote ?? entry.previous);
}

export function bodySearchMatches(cache: BodySearchCache): BodySearchMatches {
  const matches = new Map<string, RequestBodySearchMatch>();
  for (const [key, entry] of cache) {
    const match = entryMatch(entry);
    if (match) matches.set(key, match);
  }
  return matches;
}

export async function searchLocalCapture(
  records: ToolRecord[],
  terms: string[],
  signal: AbortSignal,
  cache: BodySearchCache,
  publish: () => void
): Promise<void> {
  const keys = new Set<string>();
  // Replace changed entries before awaiting, so old Android replies cannot update them.
  for (const record of records) {
    if (record.kind !== "request") continue;
    const key = requestRecordKey(record.processId, record.requestId);
    keys.add(key);
    const previous = cache.get(key);
    if (!previous || !sameSearchSource(previous.source, record)) {
      cache.delete(key);
      cache.set(key, { source: record, previous: previous && entryMatch(previous) });
    }
  }
  for (const key of cache.keys()) if (!keys.has(key)) cache.delete(key);
  let scanned = 0;
  for (const entry of cache.values()) {
    if (entry.local) continue;
    const local = await searchLocalBodies(entry.source, terms, signal);
    signal.throwIfAborted();
    entry.local = local;
    if (++scanned % 16 === 0) publish();
  }
  publish();
}

export async function searchAndroidCapture(
  terms: string[],
  client: NetworkClient,
  connection: ToolConnection,
  signal: AbortSignal,
  cache: BodySearchCache,
  publish: () => void
): Promise<void> {
  if (!client.searchBodies) return;
  while (!signal.aborted) {
    const batch = [...cache.entries()]
      .filter(([, entry]) => entry.source.processId === connection.processIdentity && entry.remote === undefined)
      .slice(0, bodySearchLimits.batchSize);
    if (batch.length === 0) {
      await yieldSearch(signal, bodySearchLimits.retryDelayMs);
      continue;
    }
    // Give other waiting requests a turn before retrying this batch.
    for (const [key, entry] of batch) {
      cache.delete(key);
      cache.set(key, entry);
    }
    let results: RequestBodySearchMatch[] = [];
    try {
      results = (
        await client.searchBodies({ requestIds: batch.map(([, entry]) => entry.source.requestId), terms }, signal)
      ).results;
    } catch (error) {
      signal.throwIfAborted();
      if (error instanceof BodySearchHttpError && error.status === 404) return;
      // A stream can reconnect while the query is still active.
      if (
        error instanceof TypeError ||
        ((error instanceof Error || error instanceof DOMException) &&
          ["AbortError", "TimeoutError"].includes(error.name)) ||
        (error instanceof BodySearchHttpError && [408, 429].includes(error.status)) ||
        (error instanceof BodySearchHttpError && error.status >= 500)
      ) {
        await yieldSearch(signal, bodySearchLimits.retryDelayMs);
        continue;
      }
    }
    signal.throwIfAborted();
    for (const [key, entry] of batch) {
      if (cache.get(key) === entry) entry.remote = results.find((r) => r.requestId === entry.source.requestId) ?? null;
    }
    publish();
  }
}
