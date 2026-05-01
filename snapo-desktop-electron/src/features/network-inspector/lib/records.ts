import {
  recordId,
  serverMatches,
  type InspectorDataState,
  type InspectorRecord,
  type RequestRecord,
  type ServerId,
  type WebSocketRecord
} from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";

export function collectRecords(
  state: InspectorDataState,
  selectedServer: ServerId | null,
  searchText: string,
  newestFirst: boolean
): InspectorRecord[] {
  return filterRecords(
    [...state.requests.values(), ...state.webSockets.values()],
    selectedServer,
    searchText,
    newestFirst
  );
}

export function filterRecords(
  records: InspectorRecord[],
  selectedServer: ServerId | null,
  searchText: string,
  newestFirst: boolean
): InspectorRecord[] {
  const search = parseUrlFilterTokens(searchText);
  const filteredRecords = records
    .filter((record) => serverMatches(selectedServer, record.server))
    .filter((record) => matchesUrlFilter(record.url, search))
    .sort((a, b) => a.startedAt - b.startedAt);
  if (newestFirst) filteredRecords.reverse();
  return filteredRecords;
}

interface UrlFilterTokens {
  includes: string[];
  excludes: string[];
}

function matchesUrlFilter(url: string, tokens: UrlFilterTokens): boolean {
  if (tokens.includes.length === 0 && tokens.excludes.length === 0) return true;
  const normalizedUrl = url.toLowerCase();
  return (
    tokens.includes.every((token) => normalizedUrl.includes(token)) &&
    !tokens.excludes.some((token) => normalizedUrl.includes(token))
  );
}

function parseUrlFilterTokens(searchText: string): UrlFilterTokens {
  const includes: string[] = [];
  const excludes: string[] = [];
  let index = 0;

  while (index < searchText.length) {
    while (index < searchText.length && isWhitespace(searchText[index])) index += 1;
    if (index >= searchText.length) break;

    const isExcluded = searchText[index] === "-";
    if (isExcluded) index += 1;
    if (index >= searchText.length) break;

    const quoted = searchText[index] === '"';
    if (quoted) index += 1;

    let value = "";
    while (index < searchText.length) {
      const current = searchText[index];
      if (quoted && current === '"') {
        index += 1;
        break;
      }
      if (!quoted && isWhitespace(current)) break;

      const escaped = escapedUrlFilterCharacter(searchText, index, quoted);
      if (escaped != null) {
        value += escaped;
        index += 2;
      } else {
        value += current;
        index += 1;
      }
    }

    if (value.trim().length === 0) continue;
    (isExcluded ? excludes : includes).push(value.toLowerCase());
  }

  return { includes, excludes };
}

function escapedUrlFilterCharacter(text: string, index: number, quoted: boolean): string | null {
  if (text[index] !== "\\") return null;
  const next = text[index + 1];
  if (next == null) return null;
  if (next === '"' || next === "\\") return next;
  return !quoted && isWhitespace(next) ? next : null;
}

function isWhitespace(value: string): boolean {
  return /\s/u.test(value);
}

export function countRecordsForServer(records: InspectorRecord[], selectedServer: ServerId | null): number {
  return records.reduce((count, record) => count + (serverMatches(selectedServer, record.server) ? 1 : 0), 0);
}

export function clearCompleted(state: InspectorDataState): InspectorDataState {
  const requests = new Map([...state.requests.entries()].filter(([, request]) => !isCompletedRequest(request)));
  const webSockets = new Map([...state.webSockets.entries()].filter(([, socket]) => !isCompletedWebSocket(socket)));
  return { ...state, requests, webSockets };
}

export function isCompletedRecord(record: InspectorRecord): boolean {
  return record.kind === "request" ? isCompletedRequest(record) : isCompletedWebSocket(record);
}

export function shouldRequestRequestBody(request: RequestRecord): boolean {
  if (request.requestBody != null) return false;
  if (request.requestHasPostData === false) return false;
  return request.requestBodySize == null || request.requestBodySize !== 0;
}

export function shouldRequestResponseBody(request: RequestRecord): boolean {
  if (request.responseBody != null) return false;
  if (request.status.kind !== "success") return false;

  if (isLikelyStreamingRequest(request)) {
    if (request.streamClosed == null) return false;
  } else if (request.endedAt == null) {
    return false;
  }

  if (responseHasNoBody(request)) return false;
  return request.encodedDataLength == null || request.encodedDataLength !== 0;
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

export function pickSelectedServer(current: ServerId | null, servers: SnapOServer[]): ServerId | null {
  if (servers.length === 0) return null;
  if (
    current != null &&
    servers.some((server) => server.deviceId === current.deviceId && server.socketName === current.socketName)
  ) {
    return current;
  }
  return { deviceId: servers[0].deviceId, socketName: servers[0].socketName };
}

export function mergeServersWithRetainedSelection(
  activeServers: SnapOServer[],
  currentServers: SnapOServer[],
  selectedServer: ServerId | null
): SnapOServer[] {
  if (selectedServer == null || activeServers.some((server) => serverMatches(selectedServer, server))) {
    return activeServers;
  }

  const retained = currentServers.find((server) => serverMatches(selectedServer, server));
  if (retained == null) return activeServers;

  return [...activeServers, { ...retained, isConnected: false }].sort((left, right) => {
    const device = left.deviceId.localeCompare(right.deviceId);
    return device !== 0 ? device : left.socketName.localeCompare(right.socketName);
  });
}

export function serverModelFor(servers: SnapOServer[], selected: ServerId | null): SnapOServer | null {
  if (selected == null) return null;
  return (
    servers.find((server) => server.deviceId === selected.deviceId && server.socketName === selected.socketName) ?? null
  );
}

export function replacementCandidate(servers: SnapOServer[], selectedServer: SnapOServer | null): SnapOServer | null {
  if (selectedServer == null || selectedServer.isConnected) return null;
  return (
    servers.find(
      (server) =>
        server.isConnected &&
        server.deviceId === selectedServer.deviceId &&
        server.displayName === selectedServer.displayName &&
        server.socketName !== selectedServer.socketName
    ) ?? null
  );
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

export function recordShowsActiveIndicator(record: InspectorRecord): boolean {
  if (record.kind === "websocket") return record.status.kind === "pending";
  return record.streamEvents.length > 0 && record.streamClosed == null;
}

function isLikelyStreamingRequest(request: RequestRecord): boolean {
  if (request.streamEvents.length > 0) return true;
  if (request.responseType?.toLowerCase() === "eventsource") return true;
  return hasEventStreamHeader(request.responseHeaders) || hasEventStreamHeader(request.requestHeaders);
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

function hasEventStreamHeader(headers: RequestRecord["requestHeaders"]): boolean {
  return headers.some((header) => {
    const name = header.name.toLowerCase();
    const value = header.value.toLowerCase();
    return (name === "content-type" || name === "accept") && value.includes("text/event-stream");
  });
}

function contentLength(headers: RequestRecord["responseHeaders"]): number | null {
  const value = headers.find((header) => header.name.toLowerCase() === "content-length")?.value.trim();
  if (value == null || value.length === 0) return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

export function sidebarPlaceholderText(input: {
  totalItems: number;
  serverScopedItems: number;
  filteredItems: number;
  selectedServer: SnapOServer | null;
}): string | null {
  if (input.totalItems === 0) return "No activity yet";
  if (input.serverScopedItems === 0) {
    if (input.selectedServer == null || !input.selectedServer.hasAppInfo) return "Waiting for connection...";
    return "No activity for this app yet";
  }
  if (input.filteredItems === 0) return "No matches";
  return null;
}

export function contextMenuExportSelection(
  clicked: InspectorRecord,
  selectedRecordId: string | null,
  allRecords: InspectorRecord[]
): InspectorRecord[] {
  const selected =
    selectedRecordId == null ? null : (allRecords.find((record) => recordId(record) === selectedRecordId) ?? null);
  if (selected == null || selected.kind !== clicked.kind || recordId(selected) === recordId(clicked)) return [clicked];
  return [selected, clicked];
}

export function resolveDetailEmptyState(input: {
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  serverScopedItems: number;
}): { title: string; body: string; showDocsLink: boolean } {
  if (input.servers.length === 0) {
    return {
      title: "No compatible apps detected",
      body: "Apps must include the `com.openai.snapo` dependencies to appear here.",
      showDocsLink: true
    };
  }
  if (input.serverScopedItems === 0) {
    const waitingForConnection = input.selectedServer == null || !input.selectedServer.hasAppInfo;
    if (waitingForConnection) {
      return {
        title: "Waiting for connection...",
        body: "Snap-O is waiting for the app to publish its network server metadata.",
        showDocsLink: false
      };
    }
    return {
      title: "No activity for this app yet",
      body: "Requests will appear here once the app makes network calls.",
      showDocsLink: false
    };
  }
  return {
    title: "Select a record",
    body: "Choose an entry to inspect its details.",
    showDocsLink: false
  };
}
