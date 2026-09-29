import { decodeRequestBody } from "./body-decoding";
import type { RequestRecord, ToolRecord } from "./cdp";
import { requestRecordKey } from "./cdp";
import type { NetworkClient } from "./client";
import type { ToolConnection } from "@snap-o/tool-host";

export class BodySearchHttpError extends Error {
  constructor(readonly status: number) {
    super(`Body search failed (${status}).`);
  }
}

export interface BodySearchMatch {
  terms: string[];
  complete: boolean;
  snippet?: string | null;
}
export interface RequestBodySearchMatch {
  requestId: string;
  request: BodySearchMatch;
  response: BodySearchMatch;
}
export interface BodySearchQuery {
  requestIds: string[];
  terms: string[];
}
export interface BodySearchReply {
  results: RequestBodySearchMatch[];
}
export type BodySearchMatches = ReadonlyMap<string, RequestBodySearchMatch>;
export const emptyBodySearchMatches: BodySearchMatches = new Map();

export async function yieldSearch(signal: AbortSignal, delay = 0): Promise<void> {
  signal.throwIfAborted();
  await new Promise<void>((resolve) => setTimeout(resolve, delay));
  signal.throwIfAborted();
}

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
    const chunk = text.slice(start, start + 16_384 + overlap).toLowerCase();
    for (const term of terms) {
      if (found.has(term)) continue;
      const offset = chunk.indexOf(term);
      if (offset < 0) continue;
      found.add(term);
      snippet ??= text.slice(Math.max(0, start + offset - 40), start + offset + 120);
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
  const request =
    requestText == null
      ? { terms: [], complete: record.requestHasPostData === false || record.requestBodySize === 0 }
      : await searchBodyText(requestText, terms, signal);
  // Missing or partial uploads cannot prove that an excluded term is absent.
  if (requestText != null) request.complete = record.requestBodyTruncatedBytes === 0;
  const response =
    responseText == null
      ? {
          terms: [],
          complete:
            record.method === "HEAD" ||
            record.encodedDataLength === 0 ||
            (record.status.kind === "success" && [204, 304].includes(record.status.code))
        }
      : await searchBodyText(responseText, terms, signal);
  if (responseText != null)
    response.complete = record.endedAt != null && (record.responseBodyTruncatedBytes ?? 0) === 0;
  return { requestId: record.requestId, request, response };
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
    for (let i = 0; i < current.length; ) {
      signal.throwIfAborted();
      const batch = current.slice(i, i + 32);
      try {
        const reply = await client.searchBodies({ requestIds: batch.map((r) => r.requestId), terms }, signal);
        signal.throwIfAborted();
        const ids = new Set(batch.map((r) => r.requestId));
        for (const result of reply.results) {
          if (!ids.has(result.requestId)) continue;
          const key = requestRecordKey(connection.processIdentity, result.requestId);
          const local = matches.get(key);
          if (local) matches.set(key, mergeBodyMatches(local, result));
          const entry = cache.get(key);
          if (entry) entry.remote = result;
        }
        publish(new Map(matches));
        i += batch.length;
      } catch (error) {
        signal.throwIfAborted();
        const retryable =
          error instanceof BodySearchHttpError
            ? error.status === 408 || error.status === 429 || error.status >= 500
            : error instanceof TypeError || (error instanceof DOMException && error.name === "TimeoutError");
        if (!retryable) break;
        await yieldSearch(signal, 500);
      }
    }
  }
  return matches;
}
