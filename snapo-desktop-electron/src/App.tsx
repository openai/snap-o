import { ArrowDownUp, ChevronDown, Copy, Inbox, Send, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { createNetworkClient } from "./network/client";
import {
  applyRequestBodies,
  createEmptyInspectorState,
  recordId,
  reduceCdpMessage,
  requestRecordKey,
  serverMatches,
  type InspectorDataState,
  type InspectorRecord,
  type RequestRecord,
  type RequestStatus,
  type ServerId,
  type WebSocketRecord
} from "./network/cdp";
import type { SnapOServer } from "./network/bridge-types";

const docsUrl = "https://github.com/openai/snap-o/blob/main/docs/network-inspector.md";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [selectedServer, setSelectedServer] = useState<ServerId | null>(null);
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [sortNewestFirst, setSortNewestFirst] = useState(false);

  useEffect(() => {
    const unsubscribeEvent = client.onEvent((event) => {
      setState((current) => reduceCdpMessage(current, event.server, event.message));
    });
    return unsubscribeEvent;
  }, [client]);

  useEffect(() => {
    let disposed = false;
    const refresh = async () => {
      const servers = await client.listServers();
      if (!disposed) {
        setState((current) => ({ ...current, servers }));
        setSelectedServer((current) => pickSelectedServer(current, servers));
      }
    };

    void refresh();
    const timer = window.setInterval(() => void refresh(), 2_000);
    return () => {
      disposed = true;
      window.clearInterval(timer);
    };
  }, [client]);

  useEffect(() => {
    if (selectedServer == null) return;
    let streamId: string | null = null;
    let disposed = false;
    client
      .startStream(selectedServer)
      .then((started) => {
        if (disposed) {
          void client.stopStream(started.streamId);
          return;
        }
        streamId = started.streamId;
      })
      .catch(() => {
        // The Compose app keeps the pane chrome quiet; connection failures surface as empty states.
      });

    return () => {
      disposed = true;
      if (streamId != null) void client.stopStream(streamId);
    };
  }, [client, selectedServer?.deviceId, selectedServer?.socketName]);

  const visibleRecords = useMemo(() => {
    return collectRecords(state, selectedServer, searchText, sortNewestFirst);
  }, [state, selectedServer, searchText, sortNewestFirst]);

  const serverRecordCount = useMemo(() => {
    return collectRecords(state, selectedServer, "", sortNewestFirst).length;
  }, [state, selectedServer, sortNewestFirst]);

  useEffect(() => {
    setSelectedRecordId((current) => {
      if (visibleRecords.length === 0) return null;
      if (current != null && visibleRecords.some((record) => recordId(record) === current)) return current;
      return recordId(visibleRecords[0]);
    });
  }, [visibleRecords]);

  const selectedRecord = useMemo(() => {
    if (selectedRecordId == null) return null;
    return visibleRecords.find((record) => recordId(record) === selectedRecordId) ?? null;
  }, [selectedRecordId, visibleRecords]);

  useEffect(() => {
    if (selectedRecord?.kind !== "request") return;
    const key = requestRecordKey(selectedRecord.server, selectedRecord.requestId);
    if (selectedRecord.requestBody != null && selectedRecord.responseBody != null) return;
    let disposed = false;
    client
      .loadBodies({
        deviceId: selectedRecord.server.deviceId,
        socketName: selectedRecord.server.socketName,
        requestId: selectedRecord.requestId
      })
      .then((bodies) => {
        if (disposed) return;
        setState((current) => {
          const currentRecord = current.requests.get(key);
          if (currentRecord == null) return current;
          const requests = new Map(current.requests);
          requests.set(key, applyRequestBodies(currentRecord, bodies));
          return { ...current, requests };
        });
      })
      .catch(() => {
        // Some requests legitimately have no body or cannot be read after completion.
      });
    return () => {
      disposed = true;
    };
  }, [client, selectedRecord?.kind, selectedRecordId]);

  const selectedServerModel = serverModelFor(state.servers, selectedServer);
  const replacementServer = replacementCandidate(state.servers, selectedServerModel);
  const sidebarPlaceholder = sidebarPlaceholderText({
    totalItems: state.requests.size + state.webSockets.size,
    serverScopedItems: serverRecordCount,
    filteredItems: visibleRecords.length,
    selectedServer: selectedServerModel
  });
  const hasClearableItems = [...state.requests.values(), ...state.webSockets.values()].some(
    (record) => record.status.kind !== "pending"
  );

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="server-picker-frame">
          <ServerSelect
            servers={state.servers}
            selectedServer={selectedServerModel}
            onChange={(server) => {
              setSelectedServer(server);
              setSelectedRecordId(null);
            }}
          />
          {replacementServer == null ? null : (
            <button
              className="replacement-banner"
              type="button"
              onClick={() => {
                setSelectedServer({ deviceId: replacementServer.deviceId, socketName: replacementServer.socketName });
                setSelectedRecordId(null);
              }}
            >
              <span>
                <span className="replacement-title">New process available</span>
                <span className="replacement-detail">
                  {replacementServer.pid == null ? "Tap to switch process" : `PID ${replacementServer.pid}`}
                </span>
              </span>
            </button>
          )}
        </div>

        <div className="filter-frame">
          <div className="search-row">
            <input
              value={searchText}
              onChange={(event) => setSearchText(event.target.value)}
              placeholder="Filter by URL"
              aria-label="Filter by URL"
            />
          </div>

          <div className="toolbar-action-group">
            <button
              className="toolbar-icon-button"
              type="button"
              title="Toggle sort order"
              aria-label="Toggle sort order"
              onClick={() => setSortNewestFirst((value) => !value)}
            >
              <ArrowDownUp size={16} className={sortNewestFirst ? "sort-icon newest" : "sort-icon"} />
            </button>
            <button
              className="toolbar-icon-button"
              type="button"
              title="Clear completed"
              aria-label="Clear completed"
              disabled={!hasClearableItems}
              onClick={() => setState(clearCompleted)}
            >
              <Trash2 size={16} />
            </button>
          </div>
        </div>

        <RecordList
          records={visibleRecords}
          placeholder={sidebarPlaceholder}
          selectedRecordId={selectedRecordId}
          onSelect={setSelectedRecordId}
        />
      </aside>

      <main className="detail-pane">
        <DetailContent
          record={selectedRecord}
          servers={state.servers}
          selectedServer={selectedServerModel}
          serverScopedItems={serverRecordCount}
          onOpenDocs={() => void client.openExternal(docsUrl)}
        />
      </main>
    </div>
  );
}

function ServerSelect(props: {
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  onChange: (server: ServerId | null) => void;
}): JSX.Element {
  const { servers, selectedServer, onChange } = props;
  if (servers.length === 0) return <div className="no-servers-banner">No Apps Found</div>;

  const value = selectedServer == null ? "" : serverOptionValue(selectedServer);
  return (
    <div className="server-select">
      <div className="server-picker-button" aria-hidden="true">
        <ServerAppIcon server={selectedServer} />
        <span className="server-picker-text">
          <span className="server-name">{selectedServer?.displayName ?? "Select an App"}</span>
          {selectedServer?.deviceDisplayTitle == null || selectedServer.deviceDisplayTitle.length === 0 ? null : (
            <span className="server-device">{selectedServer.deviceDisplayTitle}</span>
          )}
        </span>
        <ChevronDown size={18} className="server-chevron" />
      </div>
      <select
        className="server-picker-select"
        aria-label="Select an App"
        value={value}
        onChange={(event) => {
          const selected = servers.find((server) => serverOptionValue(server) === event.target.value);
          onChange(selected == null ? null : { deviceId: selected.deviceId, socketName: selected.socketName });
        }}
      >
        {selectedServer == null ? <option value="">Select an App</option> : null}
        {servers.map((server) => (
          <option key={`${server.deviceId}:${server.socketName}`} value={serverOptionValue(server)}>
            {server.displayName} · {server.deviceDisplayTitle}
          </option>
        ))}
      </select>
    </div>
  );
}

function ServerAppIcon({ server }: { server: SnapOServer | null }): JSX.Element {
  const image = server?.appIconBase64;
  return (
    <span className="server-app-icon">
      {image == null || image.length === 0 ? null : <img src={`data:image/png;base64,${image}`} alt="" />}
      {server == null ? null : <span className={`server-status-dot ${server.isConnected ? "connected" : "disconnected"}`} />}
    </span>
  );
}

function RecordList(props: {
  records: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  onSelect: (id: string) => void;
}): JSX.Element {
  if (props.placeholder != null) return <div className="sidebar-placeholder">{props.placeholder}</div>;

  return (
    <div className="record-list">
      {props.records.map((record) => {
        const id = recordId(record);
        const path = splitUrl(record.url);
        return (
          <button
            key={id}
            type="button"
            className={`record-row ${props.selectedRecordId === id ? "selected" : ""}`}
            onClick={() => props.onSelect(id)}
          >
            <span className="record-main">
              <span className="record-primary">{path.primary}</span>
              <span className="record-secondary">{path.secondary}</span>
            </span>
            <span className="record-method">{record.method}</span>
            <StatusView record={record} />
          </button>
        );
      })}
    </div>
  );
}

function DetailContent(props: {
  record: InspectorRecord | null;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  serverScopedItems: number;
  onOpenDocs: () => void;
}): JSX.Element {
  if (props.record == null) {
    const empty = resolveDetailEmptyState(props);
    return (
      <EmptyState title={empty.title} body={empty.body} showDocsLink={empty.showDocsLink} onOpenDocs={props.onOpenDocs} />
    );
  }

  if (props.record.kind === "websocket") return <WebSocketDetail record={props.record} />;
  return <RequestDetail record={props.record} />;
}

function RequestDetail({ record }: { record: RequestRecord }): JSX.Element {
  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="detail-method">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusBadge record={record} />
          <span>{formatTiming(record.startedAt, record.endedAt, record.status)}</span>
        </div>
        <FailureMessage status={record.status} />
      </header>

      {record.requestHeaders.length === 0 ? null : (
        <Section title="Request Headers">
          <HeadersTable headers={record.requestHeaders} />
        </Section>
      )}
      {hasBody(record.requestBody) ? (
        <Section title="Request Body" meta={bodyMetadata(record.requestBody, record.requestBodyEncoding)}>
          <BodyBlock body={record.requestBody} encoding={record.requestBodyEncoding} />
        </Section>
      ) : null}
      {record.status.kind === "pending" ? <div className="pending-response">Waiting for response...</div> : null}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers">
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      {record.streamEvents.length > 0 ? (
        <Section title="Server-Sent Events">
          <div className="event-list">
            {record.streamEvents.map((event) => (
              <div className="event-row" key={event.sequence}>
                <div className="event-meta">
                  <span>#{event.sequence}</span>
                  <span>{formatTime(event.timestamp)}</span>
                  {event.eventName ? <span>{event.eventName}</span> : null}
                </div>
                <pre>{event.raw || event.data || "<empty>"}</pre>
              </div>
            ))}
          </div>
        </Section>
      ) : null}
      {hasBody(record.responseBody) ? (
        <Section title="Response Body" meta={bodyMetadata(record.responseBody, record.responseBodyBase64Encoded ? "base64" : null)}>
          <BodyBlock body={record.responseBody} base64Encoded={record.responseBodyBase64Encoded} />
        </Section>
      ) : null}
    </div>
  );
}

function WebSocketDetail({ record }: { record: WebSocketRecord }): JSX.Element {
  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="detail-method">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusBadge record={record} />
          <span>{formatTiming(record.startedAt, record.endedAt, record.status)}</span>
        </div>
        <FailureMessage status={record.status} />
      </header>
      {record.requestHeaders.length === 0 ? null : (
        <Section title="Request Headers">
          <HeadersTable headers={record.requestHeaders} />
        </Section>
      )}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers">
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      <Section title="Messages">
        {record.messages.length === 0 ? (
          <div className="messages-empty">No messages yet</div>
        ) : (
          <div className="event-list">
            {record.messages.map((message) => (
              <div className="message-card" key={message.id}>
                <div className="message-meta">
                  {message.direction === "outgoing" ? (
                    <Send size={20} className="message-direction outgoing" />
                  ) : (
                    <Inbox size={20} className="message-direction incoming" />
                  )}
                  <span>{message.payloadSize == null ? "" : formatBytes(message.payloadSize)}</span>
                  <span>{message.enqueued === true ? "enqueued" : "immediate"}</span>
                  <span>{formatTime(message.timestamp)}</span>
                  <span>{message.opcode}</span>
                </div>
                <pre>{message.preview ?? "<binary or empty payload>"}</pre>
              </div>
            ))}
          </div>
        )}
      </Section>
    </div>
  );
}

function Section({ title, meta, children }: { title: string; meta?: string | null; children: React.ReactNode }): JSX.Element {
  const [expanded, setExpanded] = useState(true);
  return (
    <section className="detail-section">
      <button className="section-header" type="button" onClick={() => setExpanded((value) => !value)}>
        <span className={expanded ? "triangle expanded" : "triangle"} />
        <span>{title}</span>
        {meta == null ? null : <span className="section-meta">{meta}</span>}
      </button>
      {expanded ? children : null}
    </section>
  );
}

function HeadersTable({ headers }: { headers: Array<{ name: string; value: string }> }): JSX.Element {
  if (headers.length === 0) return <div className="headers-empty">None</div>;
  return (
    <div className="headers-grid">
      {headers.map((header, index) => (
        <div className="header-row" key={`${header.name}:${index}`}>
          <span className="header-name"> {header.name}:</span>
          <span className="header-value">  {header.value}</span>
        </div>
      ))}
    </div>
  );
}

function BodyBlock(props: {
  body?: string | null;
  encoding?: string | null;
  base64Encoded?: boolean | null;
}): JSX.Element {
  const body = props.body;
  if (body == null || body.length === 0) return <div className="headers-empty">None</div>;
  const pretty = prettyBody(body, props.base64Encoded);
  return (
    <div className="body-block">
      <div className="body-toolbar">
        <span>{props.base64Encoded ? "Base64 encoded" : props.encoding ?? "Text"}</span>
        <button className="inline-action" type="button" onClick={() => void navigator.clipboard.writeText(body)}>
          <Copy size={14} />
          Copy
        </button>
      </div>
      <pre>{pretty}</pre>
    </div>
  );
}

function StatusView({ record }: { record: InspectorRecord }): JSX.Element {
  if (recordShowsActiveIndicator(record)) return <span className="active-indicator">●</span>;
  const status = record.status;
  if (status.kind === "pending") return <span className="pending-spinner" aria-label="Pending" />;
  if (status.kind === "failure") return <span className="row-status status-error">Error</span>;
  return <span className={`row-status ${statusToneClass(status.code)}`}>{status.code}</span>;
}

function StatusBadge({ record }: { record: InspectorRecord }): JSX.Element {
  if (record.kind === "request" && record.streamEvents.length > 0 && record.streamClosed == null) {
    return <span className="status-label status-streaming">Streaming</span>;
  }
  const status = record.status;
  if (status.kind === "pending") return <span className="status-label status-pending">Pending</span>;
  if (status.kind === "failure") return <span className="status-label status-error">Error</span>;
  return <span className={`status-label ${statusToneClass(status.code)}`}>{statusDisplayName(status.code)}</span>;
}

function FailureMessage({ status }: { status: RequestStatus }): JSX.Element | null {
  if (status.kind !== "failure" || status.message == null || status.message.trim().length === 0) return null;
  return <div className="failure-message">Error: {status.message}</div>;
}

function pickSelectedServer(current: ServerId | null, servers: SnapOServer[]): ServerId | null {
  if (servers.length === 0) return null;
  if (current != null && servers.some((server) => server.deviceId === current.deviceId && server.socketName === current.socketName)) {
    return current;
  }
  return { deviceId: servers[0].deviceId, socketName: servers[0].socketName };
}

function serverModelFor(servers: SnapOServer[], selected: ServerId | null): SnapOServer | null {
  if (selected == null) return null;
  return servers.find((server) => server.deviceId === selected.deviceId && server.socketName === selected.socketName) ?? null;
}

function replacementCandidate(servers: SnapOServer[], selectedServer: SnapOServer | null): SnapOServer | null {
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

function serverOptionValue(server: SnapOServer): string {
  return `${server.deviceId}\u0000${server.socketName}`;
}

function collectRecords(
  state: InspectorDataState,
  selectedServer: ServerId | null,
  searchText: string,
  newestFirst: boolean
): InspectorRecord[] {
  const query = searchText.trim().toLowerCase();
  const records = [...state.requests.values(), ...state.webSockets.values()]
    .filter((record) => serverMatches(selectedServer, record.server))
    .filter((record) => (query.length === 0 ? true : record.url.toLowerCase().includes(query)))
    .sort((a, b) => a.startedAt - b.startedAt);
  if (newestFirst) records.reverse();
  return records;
}

function clearCompleted(state: InspectorDataState): InspectorDataState {
  const requests = new Map(
    [...state.requests.entries()].filter(([, request]) => request.status.kind === "pending" || request.streamEvents.length > 0)
  );
  const webSockets = new Map([...state.webSockets.entries()].filter(([, socket]) => socket.status.kind === "pending"));
  return { ...state, requests, webSockets };
}

function splitUrl(url: string): { primary: string; secondary: string } {
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

function prettyBody(body: string, base64Encoded?: boolean | null): string {
  if (base64Encoded) return body;
  try {
    return JSON.stringify(JSON.parse(body), null, 2);
  } catch {
    return body;
  }
}

function formatTiming(startedAt: number, endedAt: number | undefined, status: RequestStatus): string {
  const startSegment = `Started ${formatRelative(startedAt)} at ${formatTimeWithMillis(startedAt)}`;
  if (status.kind === "pending" || endedAt == null) return startSegment;
  return `${formatDuration(Math.max(0, endedAt - startedAt))} total • ${startSegment}`;
}

function formatDuration(durationMs: number): string {
  const seconds = durationMs / 1000;
  if (seconds < 1) return `${Math.round(durationMs)} ms`;
  if (seconds < 10) return `${seconds.toFixed(2)} s`;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  return `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s`;
}

function formatTime(value: number): string {
  return new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(value));
}

function formatTimeWithMillis(value: number): string {
  const date = new Date(value);
  const hours = date.getHours();
  const minutes = `${date.getMinutes()}`.padStart(2, "0");
  const seconds = `${date.getSeconds()}`.padStart(2, "0");
  const millis = `${date.getMilliseconds()}`.padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${millis}`;
}

function formatRelative(value: number): string {
  const seconds = Math.round((Date.now() - value) / 1000);
  if (seconds === 0) return "just now";
  const absoluteSeconds = Math.abs(seconds);
  const isFuture = seconds < 0;
  const [amount, unit] =
    absoluteSeconds < 60
      ? [absoluteSeconds, "s"]
      : absoluteSeconds < 3600
        ? [Math.floor(absoluteSeconds / 60), "m"]
        : absoluteSeconds < 86400
          ? [Math.floor(absoluteSeconds / 3600), "h"]
          : [Math.floor(absoluteSeconds / 86400), "d"];
  return isFuture ? `in ${amount}${unit}` : `${amount}${unit} ago`;
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

function hasBody(value: string | null | undefined): value is string {
  return value != null && value.length > 0;
}

function bodyMetadata(body: string | null | undefined, encoding: string | null | undefined): string | null {
  if (!hasBody(body)) return null;
  const bytes = new TextEncoder().encode(body).length;
  const suffix = encoding == null || encoding.length === 0 ? "Text" : encoding;
  return `${formatBytes(bytes)} • ${suffix}`;
}

function recordShowsActiveIndicator(record: InspectorRecord): boolean {
  if (record.kind === "websocket") return record.status.kind === "pending";
  return record.streamEvents.length > 0 && record.streamClosed == null;
}

function statusToneClass(code: number): string {
  if (code >= 200 && code <= 299) return "status-success";
  if (code >= 400 && code <= 599) return "status-error";
  if (code >= 300 && code <= 399) return "status-warning";
  return "status-info";
}

function statusDisplayName(code: number): string {
  const overrides: Record<number, string> = {
    200: "OK",
    201: "Created",
    202: "Accepted",
    204: "No Content",
    301: "Moved Permanently",
    302: "Found",
    304: "Not Modified",
    307: "Temporary Redirect",
    308: "Permanent Redirect",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    410: "Gone",
    422: "Unprocessable Entity",
    429: "Too Many Requests",
    500: "Internal Server Error",
    501: "Not Implemented",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout"
  };
  return `${code} ${overrides[code] ?? "Done"}`;
}

function sidebarPlaceholderText(input: {
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

function resolveDetailEmptyState(input: {
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

function EmptyState(props: {
  title: string;
  body: string;
  showDocsLink: boolean;
  onOpenDocs: () => void;
}): JSX.Element {
  return (
    <section className="empty-detail">
      <h1>{props.title}</h1>
      <p>{props.body}</p>
      {props.showDocsLink ? (
        <button className="text-button" type="button" onClick={props.onOpenDocs}>
          Read the developer guide
        </button>
      ) : null}
    </section>
  );
}
