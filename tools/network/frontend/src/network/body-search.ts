import { findTextMatches } from "./text-matcher";
import { responseBodyCoverage, requestBodyCoverage, type BodyCoverage } from "./body-coverage";
import { decodeRequestBody } from "./body-decoding";
import type { RequestRecord, ToolRecord } from "./cdp";
import { requestRecordKey } from "./cdp";
import type { NetworkClient } from "./client";
import type { ToolConnection } from "@snap-o/tool-host";

import { yieldSearch, type BodySearchMatch, type RequestBodySearchMatch } from "./remote-body-search";
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
  local: RequestBodySearchMatch;
  remote?: RequestBodySearchMatch;
}

// Reuse results for one query and connection. Remove entries when their records are removed.
export type BodySearchCache = Map<string, CachedBodySearch>;

function sameSearchSource(a: RequestRecord, b: RequestRecord): boolean {
  return (
    a.updatedAt === b.updatedAt &&
    a.requestBody === b.requestBody &&
    a.requestBodyEncoding === b.requestBodyEncoding &&
    a.requestBodySize === b.requestBodySize &&
    a.requestBodyTruncatedBytes === b.requestBodyTruncatedBytes &&
    a.requestHasPostData === b.requestHasPostData &&
    a.requestHeaders === b.requestHeaders &&
    a.responseBody === b.responseBody &&
    a.responseBodyBase64Encoded === b.responseBodyBase64Encoded &&
    a.responseBodyTruncatedBytes === b.responseBodyTruncatedBytes &&
    a.endedAt === b.endedAt &&
    a.encodedDataLength === b.encodedDataLength &&
    a.hasReceivedResponse === b.hasReceivedResponse &&
    a.status === b.status
  );
}

export async function searchCaptureBodies(
  records: ToolRecord[],
  terms: string[],
  client: NetworkClient,
  connection: ToolConnection | null,
  signal: AbortSignal,
  publish: (matches: BodySearchMatches) => void,
  cache: BodySearchCache = new Map()
): Promise<BodySearchMatches> {
  const matches = new Map<string, RequestBodySearchMatch>();
  const requests = records.filter((r): r is RequestRecord => r.kind === "request");
  const keys = new Set(requests.map((record) => requestRecordKey(record.processId, record.requestId)));
  for (const key of cache.keys()) if (!keys.has(key)) cache.delete(key);
  for (let i = 0; i < requests.length; i++) {
    const record = requests[i];
    signal.throwIfAborted();
    const key = requestRecordKey(record.processId, record.requestId);
    let entry = cache.get(key);
    if (!entry || !sameSearchSource(entry.source, record)) {
      entry = { source: record, local: await searchLocalBodies(record, terms, signal) };
      cache.set(key, entry);
    }
    matches.set(key, entry.remote ? mergeBodyMatches(entry.local, entry.remote) : entry.local);
    if (i % 16 === 15) publish(new Map(matches));
  }
  publish(new Map(matches));
  if (connection && client.searchBodies) {
    const current = requests.filter(
      (r) =>
        r.processId === connection.processIdentity && !cache.get(requestRecordKey(r.processId, r.requestId))?.remote
    );
    const accept = (reply: { results: RequestBodySearchMatch[] }) => {
      signal.throwIfAborted();
      for (const result of reply.results) {
        const key = requestRecordKey(connection.processIdentity, result.requestId);
        const entry = cache.get(key);
        if (!entry) continue;
        entry.remote = result;
        matches.set(key, mergeBodyMatches(entry.local, result));
      }
      publish(new Map(matches));
    };
    await client.searchBodies({ requestIds: current.map((r) => r.requestId), terms }, signal, accept);
  }
  return matches;
}
