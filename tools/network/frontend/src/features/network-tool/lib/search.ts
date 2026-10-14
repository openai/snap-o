import { findTextMatches } from "../../../network/text-matcher";
import type { RequestBodySearchMatch } from "../../../network/remote-body-search";
import {
  matchesKeywordSearchDocument,
  parseKeywordSearchQuery,
  type KeywordSearchDocument,
  type KeywordSearchQuery
} from "../../../network/keyword-search";
import type { Header, ToolRecord } from "../../../network/cdp";
import { formatBytes } from "../../../network/payload";
import { statusDisplayName } from "./format";

export type NetworkSearchQuery = KeywordSearchQuery;

export function parseNetworkSearchQuery(searchText: string): NetworkSearchQuery {
  return parseKeywordSearchQuery(searchText);
}

export function matchesNetworkSearch(
  record: ToolRecord,
  query: NetworkSearchQuery,
  body?: RequestBodySearchMatch | null
): boolean {
  const document = searchDocumentForRecord(record);
  if (body === undefined || record.kind !== "request") return matchesKeywordSearchDocument(document, query);
  const metadataTerms = [...findTextMatches(document.parts.join("\n"), [...query.includes, ...query.excludes], 1)].map(
    (match) => match.term
  );
  const terms = new Set([...metadataTerms, ...(body?.request.terms ?? []), ...(body?.response.terms ?? [])]);
  const contains = (term: string) => terms.has(term);
  if (!query.includes.every(contains) || query.excludes.some(contains)) return false;
  // Missing bodies cannot prove that an excluded term is absent.
  return query.excludes.length === 0 || (body?.request.complete === true && body.response.complete);
}

export function searchDocumentForRecord(record: ToolRecord): KeywordSearchDocument {
  const parts = [record.url, record.method, statusSearchText(record)];
  parts.push(...headersSearchText(record.requestHeaders), ...headersSearchText(record.responseHeaders));

  if (record.kind === "request") {
    // Bodies are searched separately on both the desktop and Android.
    for (const event of record.streamEvents) {
      parts.push(
        event.eventName ?? "",
        event.lastEventId ?? "",
        event.comment ?? "",
        event.data ?? event.raw,
        event.retryMillis == null ? "" : String(event.retryMillis)
      );
    }
    const closed = record.streamClosed;
    if (closed != null && closed.reason !== "completed") {
      parts.push(closed.message?.trim() || (closed.reason === "error" ? "Connection error." : closed.reason));
    }
  } else {
    for (const message of record.messages) {
      parts.push(
        message.opcode,
        message.preview ?? "",
        message.payloadSize == null ? "" : formatBytes(message.payloadSize),
        message.enqueued == null ? "" : message.enqueued ? "enqueued" : "immediate"
      );
    }
    if (record.closeRequested != null) {
      parts.push(
        String(record.closeRequested.code),
        record.closeRequested.reason ?? "",
        record.closeRequested.initiated,
        record.closeRequested.accepted ? "accepted" : "not accepted"
      );
    }
    if (record.closing != null) parts.push(String(record.closing.code), record.closing.reason ?? "");
    if (record.closed != null) parts.push(String(record.closed.code), record.closed.reason ?? "");
    if (record.failed != null) parts.push(record.failed.message ?? "");
  }

  return { parts };
}

function headersSearchText(headers: Header[]): string[] {
  return headers.flatMap((header) => [header.name, header.value, `${header.name}: ${header.value}`]);
}

function statusSearchText(record: ToolRecord): string {
  const status = record.status;
  if (status.kind === "pending") return record.kind === "websocket" ? "Pending" : "";
  if (status.kind === "failure") return `Error ${status.message ?? ""}`;
  return `${status.code} ${statusDisplayName(status.code)}`;
}
