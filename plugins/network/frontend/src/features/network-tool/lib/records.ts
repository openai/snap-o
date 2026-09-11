import {
  recordId,
  type ToolDataState,
  type ToolRecord,
  type RequestRecord,
  type WebSocketRecord
} from "../../../network/cdp";
import { isLikelyStreamingRequest } from "../../../network/request-classification";
import { bodyMetadata } from "../../../network/payload";
import { matchesNetworkSearch, parseNetworkSearchQuery } from "./search";

export function filterRecords(
  records: ToolRecord[],
  searchText: string,
  newestFirst: boolean,
  exclusionFilters: readonly string[] = []
): ToolRecord[] {
  // Parse separately so unfinished search syntax cannot consume saved exclusions.
  const searchQuery = parseNetworkSearchQuery(searchText);
  const exclusionQuery = parseNetworkSearchQuery(exclusionFilters.join(" "));
  searchQuery.includes.push(...exclusionQuery.includes);
  searchQuery.excludes.push(...exclusionQuery.excludes);
  const filteredRecords = records
    .filter((record) => matchesNetworkSearch(record, searchQuery))
    .sort((a, b) => a.startedAt - b.startedAt);
  if (newestFirst) filteredRecords.reverse();
  return filteredRecords;
}

export function countExcludedRecords(records: ToolRecord[], exclusionFilters: readonly string[]): number {
  if (exclusionFilters.length === 0) return 0;

  const exclusionQuery = parseNetworkSearchQuery(exclusionFilters.join(" "));
  return records.reduce((count, record) => count + (!matchesNetworkSearch(record, exclusionQuery) ? 1 : 0), 0);
}

export function clearCompleted(state: ToolDataState): ToolDataState {
  const requests = new Map([...state.requests.entries()].filter(([, request]) => !isCompletedRequest(request)));
  const webSockets = new Map([...state.webSockets.entries()].filter(([, socket]) => !isCompletedWebSocket(socket)));
  return { ...state, requests, webSockets };
}

export function isCompletedRecord(record: ToolRecord): boolean {
  return record.kind === "request" ? isCompletedRequest(record) : isCompletedWebSocket(record);
}

export function shouldRequestRequestBody(request: RequestRecord): boolean {
  if (request.requestBody != null) return false;
  if (request.requestHasPostData === false) return false;
  if (!request.hasReceivedResponse && request.status.kind !== "failure") return false;
  return request.requestBodySize == null || request.requestBodySize !== 0;
}

export function shouldRequestResponseBody(request: RequestRecord): boolean {
  if (request.responseBody != null) return false;
  if (request.responseBodyLoadCompleted) return false;
  if (request.status.kind !== "success") return false;

  if (isLikelyStreamingRequest(request)) {
    if (request.streamClosed == null) return false;
  } else if (request.endedAt == null) {
    return false;
  }

  if (responseHasNoBody(request)) return false;
  return request.encodedDataLength == null || request.encodedDataLength !== 0;
}

export function responseBodyCaptureMetadata(request: RequestRecord): string | null {
  const totalBytes = request.encodedDataLength;
  if (totalBytes == null) return null;
  const truncatedBytes = Math.max(0, request.responseBodyTruncatedBytes ?? 0);
  return bodyMetadata({
    capturedBytes: Math.max(0, totalBytes - truncatedBytes),
    totalBytes
  });
}

function isCompletedRequest(request: RequestRecord): boolean {
  if (request.status.kind === "failure") return true;
  if (request.streamClosed != null) return true;
  if (request.streamEvents.length > 0) return false;
  if (isLikelyStreamingRequest(request)) return false;
  return request.status.kind === "success" && request.endedAt != null;
}

function isCompletedWebSocket(socket: WebSocketRecord): boolean {
  return socket.failed != null || socket.cancelled != null || socket.closed != null || socket.closing != null;
}

export function splitUrl(url: string): { primary: string; secondary: string } {
  try {
    const parsed = new URL(url);
    const parts = parsed.pathname.split("/").filter(Boolean);
    if (parts.length > 0) {
      const primary = `${parts.at(-1) ?? parsed.pathname}${parsed.search}`;
      const remaining = parts.slice(0, -1);
      const secondary = remaining.length > 0 ? `/${remaining.join("/")}` : "/";
      return { primary, secondary };
    }
    return { primary: `${parsed.host}${parsed.search}`, secondary: "" };
  } catch {
    return { primary: url, secondary: "" };
  }
}

export function recordShowsActiveIndicator(record: ToolRecord): boolean {
  if (record.kind === "websocket") return record.status.kind === "pending";
  return record.streamEvents.length > 0 && record.streamClosed == null;
}

function responseHasNoBody(request: RequestRecord): boolean {
  if (request.method.toUpperCase() === "HEAD") return true;
  const status = request.status.kind === "success" ? request.status.code : null;
  if (status != null) {
    if (status >= 100 && status <= 199) return true;
    if (status === 204 || status === 205 || status === 304) return true;
  }
  return contentLength(request.responseHeaders) === 0;
}

function contentLength(headers: RequestRecord["responseHeaders"]): number | null {
  const value = headers.find((header) => header.name.toLowerCase() === "content-length")?.value.trim();
  if (value == null || value.length === 0) return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

export function sidebarPlaceholderText(input: {
  totalItems: number;
  filteredItems: number;
  streamIsRetrying?: boolean;
}): string | null {
  if (input.streamIsRetrying && input.totalItems === 0) return "Reconnecting to network stream";
  if (input.totalItems === 0) return "No activity yet";
  if (input.filteredItems === 0) return "No matches";
  return null;
}

export function contextMenuExportSelection(
  clicked: ToolRecord,
  selectedRecordId: string | null,
  allRecords: ToolRecord[]
): ToolRecord[] {
  const selected =
    selectedRecordId == null ? null : (allRecords.find((record) => recordId(record) === selectedRecordId) ?? null);
  if (selected == null || selected.kind !== clicked.kind || recordId(selected) === recordId(clicked)) return [clicked];
  return [selected, clicked];
}

export function resolveDetailEmptyState(input: {
  isConnected: boolean;
  totalItems: number;
  streamIsRetrying?: boolean;
}): { title: string; body: string } {
  if (input.totalItems === 0) {
    if (input.streamIsRetrying)
      return {
        title: "Reconnecting",
        body: "Snap-O will resume capturing requests when the network stream is available."
      };
    if (!input.isConnected)
      return {
        title: "Waiting for connection",
        body: "Open the app on your device to connect."
      };
    return {
      title: "No activity for this app yet",
      body: "Requests will appear here once the app makes network calls."
    };
  }
  return { title: "Select a record", body: "Choose an entry to inspect its details." };
}
