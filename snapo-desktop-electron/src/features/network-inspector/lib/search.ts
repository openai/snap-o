import {
  matchesKeywordSearchDocument,
  parseKeywordSearchQuery,
  type KeywordSearchDocument,
  type KeywordSearchQuery
} from "../../../network/keyword-search";
import type { Header, InspectorRecord, RequestStatus } from "../../../network/cdp";
import { formatBytes } from "../../../network/payload";
import { statusDisplayName } from "./format";

export type NetworkSearchQuery = KeywordSearchQuery;

export interface NetworkSearchContext {
  requestBodyDisplayText?: string | null;
}

export function parseNetworkSearchQuery(searchText: string): NetworkSearchQuery {
  return parseKeywordSearchQuery(searchText);
}

export function matchesNetworkSearch(
  record: InspectorRecord,
  query: NetworkSearchQuery,
  context: NetworkSearchContext = {}
): boolean {
  return matchesKeywordSearchDocument(searchDocumentForRecord(record, context), query);
}

export function searchDocumentForRecord(
  record: InspectorRecord,
  context: NetworkSearchContext = {}
): KeywordSearchDocument {
  const parts = [record.url, record.method, statusSearchText(record.status)];
  parts.push(...headersSearchText(record.requestHeaders), ...headersSearchText(record.responseHeaders));

  if (record.kind === "request") {
    parts.push(context.requestBodyDisplayText ?? record.requestBody ?? "", record.responseBody ?? "");
    for (const event of record.streamEvents) {
      parts.push(
        event.eventName ?? "",
        event.eventId ?? "",
        event.lastEventId ?? "",
        event.comment ?? "",
        event.data ?? "",
        event.raw,
        event.retryMillis == null ? "" : String(event.retryMillis)
      );
    }
    if (record.streamClosed != null) {
      parts.push(
        record.streamClosed.reason,
        record.streamClosed.message ?? "",
        record.streamClosed.totalEvents == null ? "" : String(record.streamClosed.totalEvents),
        record.streamClosed.totalBytes == null ? "" : String(record.streamClosed.totalBytes)
      );
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
    if (record.closeReason != null) parts.push(record.closeReason);
  }

  return { parts };
}

function headersSearchText(headers: Header[]): string[] {
  return headers.flatMap((header) => [header.name, header.value, `${header.name}: ${header.value}`]);
}

function statusSearchText(status: RequestStatus): string {
  if (status.kind === "pending") return "Pending";
  if (status.kind === "failure") return `Error ${status.message ?? ""}`;
  return `${status.code} ${statusDisplayName(status.code)}`;
}
