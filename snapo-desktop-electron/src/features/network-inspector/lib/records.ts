import {
  recordId,
  serverMatches,
  type InspectorDataState,
  type InspectorRecord,
  type ServerId
} from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";

export function collectRecords(
  state: InspectorDataState,
  selectedServer: ServerId | null,
  searchText: string,
  newestFirst: boolean
): InspectorRecord[] {
  return filterRecords([...state.requests.values(), ...state.webSockets.values()], selectedServer, searchText, newestFirst);
}

export function filterRecords(
  records: InspectorRecord[],
  selectedServer: ServerId | null,
  searchText: string,
  newestFirst: boolean
): InspectorRecord[] {
  const query = searchText.trim().toLowerCase();
  const filteredRecords = records
    .filter((record) => serverMatches(selectedServer, record.server))
    .filter((record) => (query.length === 0 ? true : record.url.toLowerCase().includes(query)))
    .sort((a, b) => a.startedAt - b.startedAt);
  if (newestFirst) filteredRecords.reverse();
  return filteredRecords;
}

export function countRecordsForServer(records: InspectorRecord[], selectedServer: ServerId | null): number {
  return records.reduce((count, record) => count + (serverMatches(selectedServer, record.server) ? 1 : 0), 0);
}

export function clearCompleted(state: InspectorDataState): InspectorDataState {
  const requests = new Map(
    [...state.requests.entries()].filter(([, request]) => request.status.kind === "pending" || request.streamEvents.length > 0)
  );
  const webSockets = new Map([...state.webSockets.entries()].filter(([, socket]) => socket.status.kind === "pending"));
  return { ...state, requests, webSockets };
}

export function pickSelectedServer(current: ServerId | null, servers: SnapOServer[]): ServerId | null {
  if (servers.length === 0) return null;
  if (current != null && servers.some((server) => server.deviceId === current.deviceId && server.socketName === current.socketName)) {
    return current;
  }
  return { deviceId: servers[0].deviceId, socketName: servers[0].socketName };
}

export function serverModelFor(servers: SnapOServer[], selected: ServerId | null): SnapOServer | null {
  if (selected == null) return null;
  return servers.find((server) => server.deviceId === selected.deviceId && server.socketName === selected.socketName) ?? null;
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

export function sidebarPlaceholderText(input: {
  totalItems: number;
  serverScopedItems: number;
  filteredItems: number;
  selectedServer: SnapOServer | null;
}): string | null {
  if (input.totalItems === 0) return "No activity yet";
  if (input.serverScopedItems === 0) {
    if (input.selectedServer == null || !input.selectedServer.hasHello) return "Waiting for connection...";
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
  const selected = selectedRecordId == null ? null : allRecords.find((record) => recordId(record) === selectedRecordId) ?? null;
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
  if (
    input.selectedServer != null &&
    input.serverScopedItems === 0 &&
    input.selectedServer.hasHello &&
    !input.selectedServer.features.includes("network")
  ) {
    return {
      title: `Network Inspector in ${input.selectedServer.displayName} not found`,
      body: "The server is connected, but the network feature is either not installed or not enabled.",
      showDocsLink: true
    };
  }
  if (input.serverScopedItems === 0) {
    const waitingForConnection = input.selectedServer == null || !input.selectedServer.hasHello;
    if (waitingForConnection) {
      return {
        title: "Waiting for connection...",
        body: "Snap-O is waiting for the app to accept the link connection.",
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
