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

export function createBodySearch({
  terms,
  client,
  connection,
  onResults
}: {
  terms: string[];
  client: NetworkClient;
  connection: ToolConnection | null;
  onResults: (matches: BodySearchMatches) => void;
}) {
  // Jobs write to their own entries; replaced entries are never published.
  const entries = new Map<string, CachedBodySearch>();
  const abort = new AbortController();
  const { signal } = abort;
  let localRunning = false;
  let remoteRunning = false;
  let remoteSupported = true;

  function publish() {
    if (signal.aborted) return;
    const matches = new Map<string, RequestBodySearchMatch>();
    for (const [key, entry] of entries) {
      const match = entryMatch(entry);
      if (match) matches.set(key, match);
    }
    onResults(matches);
  }

  async function searchLocal() {
    if (localRunning) return;
    localRunning = true;
    try {
      let scanned = 0;
      for (const entry of entries.values()) {
        if (entry.local) continue;
        entry.local = await searchLocalBodies(entry.source, terms, signal);
        if (++scanned % 16 === 0) publish();
      }
    } finally {
      localRunning = false;
      publish();
    }
  }

  async function searchAndroid() {
    if (remoteRunning || !client.searchBodies || !connection || !remoteSupported) return;
    remoteRunning = true;
    try {
      while (!signal.aborted) {
        const batch = [...entries.entries()]
          .filter(([, entry]) => entry.source.processId === connection.processIdentity && entry.remote === undefined)
          .slice(0, bodySearchLimits.batchSize);
        if (batch.length === 0) return;
        // Give other waiting requests a turn before retrying this batch.
        for (const [key, entry] of batch) {
          entries.delete(key);
          entries.set(key, entry);
        }
        let results: RequestBodySearchMatch[] = [];
        try {
          results = (
            await client.searchBodies({ requestIds: batch.map(([, entry]) => entry.source.requestId), terms }, signal)
          ).results;
        } catch (error) {
          signal.throwIfAborted();
          if (error instanceof BodySearchHttpError && error.status === 404) {
            remoteSupported = false;
            return;
          }
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
        for (const [, entry] of batch) {
          entry.remote = results.find((r) => r.requestId === entry.source.requestId) ?? null;
        }
        publish();
      }
    } finally {
      remoteRunning = false;
    }
  }

  return {
    update(records: ToolRecord[]) {
      if (signal.aborted) return;
      const keys = new Set<string>();
      let changed = false;
      for (const record of records) {
        if (record.kind !== "request") continue;
        const key = requestRecordKey(record.processId, record.requestId);
        keys.add(key);
        const previous = entries.get(key);
        if (!previous || !sameSearchSource(previous.source, record)) {
          entries.delete(key);
          entries.set(key, { source: record, previous: previous && entryMatch(previous) });
          changed = true;
        }
      }
      for (const key of entries.keys()) {
        if (!keys.has(key)) {
          entries.delete(key);
          changed = true;
        }
      }
      if (!changed) return;
      publish();
      void searchLocal().catch(() => {});
      void searchAndroid().catch(() => {});
    },
    dispose() {
      abort.abort();
      entries.clear();
    }
  };
}
