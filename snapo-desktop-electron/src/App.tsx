import { Check, ChevronsUpDown, Circle, Download, ExternalLink, RotateCw, Search, Trash2, Wifi } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { createNetworkClient } from "./network/client";
import type { NetworkClient } from "./network/client";
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
import type { SnapOServer, StreamStatus } from "./network/bridge-types";

const docsUrl = "https://github.com/openai/snap-o/blob/main/docs/network-inspector.md";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [selectedServer, setSelectedServer] = useState<ServerId | null>(null);
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const [streamStatus, setStreamStatus] = useState<StreamStatus | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    const unsubscribeEvent = client.onEvent((event) => {
      setState((current) => reduceCdpMessage(current, event.server, event.message));
    });
    const unsubscribeStatus = client.onStatus(setStreamStatus);
    return () => {
      unsubscribeEvent();
      unsubscribeStatus();
    };
  }, [client]);

  useEffect(() => {
    let disposed = false;
    const refresh = async () => {
      setRefreshing(true);
      try {
        const servers = await client.listServers();
        if (!disposed) {
          setState((current) => ({ ...current, servers }));
          setSelectedServer((current) => pickSelectedServer(current, servers));
        }
      } finally {
        if (!disposed) setRefreshing(false);
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
      .catch((error: Error) => {
        if (!disposed) {
          setStreamStatus({
            streamId: "local",
            state: "error",
            message: error.message
          });
        }
      });

    return () => {
      disposed = true;
      if (streamId != null) void client.stopStream(streamId);
    };
  }, [client, selectedServer?.deviceId, selectedServer?.socketName]);

  const visibleRecords = useMemo(() => {
    return collectRecords(state, selectedServer, searchText, sortNewestFirst);
  }, [state, selectedServer, searchText, sortNewestFirst]);

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

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="toolbar">
          <div className="brand">
            <Wifi size={18} />
            <span>Network Inspector</span>
          </div>
          <button
            className="icon-button"
            type="button"
            title="Refresh"
            onClick={() => void refreshServers(client, setState, setSelectedServer)}
          >
            <RotateCw size={16} className={refreshing ? "spinning" : ""} />
          </button>
        </div>

        <ServerSelect
          servers={state.servers}
          selectedServer={selectedServer}
          onChange={(server) => {
            setSelectedServer(server);
            setSelectedRecordId(null);
          }}
        />

        <div className="search-row">
          <Search size={15} />
          <input
            value={searchText}
            onChange={(event) => setSearchText(event.target.value)}
            placeholder="Filter URLs"
            aria-label="Filter URLs"
          />
        </div>

        <div className="list-actions">
          <button type="button" onClick={() => setSortNewestFirst((value) => !value)}>
            <ChevronsUpDown size={15} />
            {sortNewestFirst ? "Newest" : "Oldest"}
          </button>
          <button type="button" onClick={() => setState(clearCompleted)}>
            <Trash2 size={15} />
            Clear
          </button>
        </div>

        <RecordList
          records={visibleRecords}
          selectedRecordId={selectedRecordId}
          onSelect={setSelectedRecordId}
        />
      </aside>

      <main className="detail-pane">
        <TopBar
          server={selectedServerModel}
          status={streamStatus}
          onOpenDocs={() => void client.openExternal(docsUrl)}
        />
        <DetailContent record={selectedRecord} />
      </main>
    </div>
  );
}

function ServerSelect(props: {
  servers: SnapOServer[];
  selectedServer: ServerId | null;
  onChange: (server: ServerId | null) => void;
}): JSX.Element {
  const { servers, selectedServer, onChange } = props;
  const value = selectedServer == null ? "" : `${selectedServer.deviceId}\u0000${selectedServer.socketName}`;

  return (
    <label className="server-select">
      <span>App Server</span>
      <select
        value={value}
        onChange={(event) => {
          const selected = servers.find((server) => `${server.deviceId}\u0000${server.socketName}` === event.target.value);
          onChange(selected == null ? null : { deviceId: selected.deviceId, socketName: selected.socketName });
        }}
      >
        {servers.length === 0 ? (
          <option value="">No compatible apps detected</option>
        ) : (
          servers.map((server) => (
            <option key={`${server.deviceId}:${server.socketName}`} value={`${server.deviceId}\u0000${server.socketName}`}>
              {server.displayName} · {server.deviceDisplayTitle}
            </option>
          ))
        )}
      </select>
    </label>
  );
}

function RecordList(props: {
  records: InspectorRecord[];
  selectedRecordId: string | null;
  onSelect: (id: string) => void;
}): JSX.Element {
  if (props.records.length === 0) {
    return (
      <div className="empty-list">
        <Circle size={18} />
        <span>No network activity yet</span>
      </div>
    );
  }

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
            <span className={`method-badge ${record.kind === "websocket" ? "socket" : ""}`}>{record.method}</span>
            <span className="record-main">
              <span className="record-primary">{path.primary}</span>
              <span className="record-secondary">{path.secondary}</span>
            </span>
            <StatusPill status={record.status} compact />
          </button>
        );
      })}
    </div>
  );
}

function TopBar(props: {
  server: SnapOServer | null;
  status: StreamStatus | null;
  onOpenDocs: () => void;
}): JSX.Element {
  const server = props.server;
  return (
    <div className="top-bar">
      <div>
        <div className="top-title">{server?.displayName ?? "Snap-O Network Inspector"}</div>
        <div className="top-subtitle">
          {server == null ? "Waiting for a Snap-O link server" : `${server.deviceDisplayTitle} · ${server.socketName}`}
        </div>
      </div>
      <div className="top-actions">
        <span className={`connection-state ${props.status?.state === "error" ? "error" : ""}`}>
          {props.status?.message ?? (server == null ? "Disconnected" : "Ready")}
        </span>
        <button type="button" onClick={props.onOpenDocs}>
          <ExternalLink size={15} />
          Docs
        </button>
      </div>
    </div>
  );
}

function DetailContent(props: { record: InspectorRecord | null }): JSX.Element {
  if (props.record == null) {
    return (
      <section className="empty-detail">
        <h1>Select a record</h1>
        <p>Requests, server-sent events, and WebSocket messages will appear here once the selected app emits traffic.</p>
      </section>
    );
  }

  if (props.record.kind === "websocket") {
    return <WebSocketDetail record={props.record} />;
  }
  return <RequestDetail record={props.record} />;
}

function RequestDetail({ record }: { record: RequestRecord }): JSX.Element {
  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="method-badge large">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusPill status={record.status} />
          <span>{formatDuration(record.startedAt, record.endedAt)}</span>
          {record.encodedDataLength != null ? <span>{formatBytes(record.encodedDataLength)}</span> : null}
        </div>
      </header>

      <Section title="Request Headers">
        <HeadersTable headers={record.requestHeaders} />
      </Section>
      <Section title="Request Body">
        <BodyBlock body={record.requestBody} encoding={record.requestBodyEncoding} />
      </Section>
      <Section title="Response Headers">
        <HeadersTable headers={record.responseHeaders} />
      </Section>
      <Section title="Response Body">
        <BodyBlock body={record.responseBody} base64Encoded={record.responseBodyBase64Encoded} />
      </Section>
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
    </div>
  );
}

function WebSocketDetail({ record }: { record: WebSocketRecord }): JSX.Element {
  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="method-badge large socket">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusPill status={record.status} />
          <span>{formatDuration(record.startedAt, record.endedAt)}</span>
          <span>{record.messages.length} messages</span>
        </div>
      </header>
      <Section title="Handshake Request">
        <HeadersTable headers={record.requestHeaders} />
      </Section>
      <Section title="Handshake Response">
        <HeadersTable headers={record.responseHeaders} />
      </Section>
      <Section title="Messages">
        {record.messages.length === 0 ? (
          <div className="empty-block">No messages captured yet.</div>
        ) : (
          <div className="event-list">
            {record.messages.map((message) => (
              <div className="event-row" key={message.id}>
                <div className="event-meta">
                  <span>{message.direction === "outgoing" ? "Sent" : "Received"}</span>
                  <span>{message.opcode}</span>
                  <span>{formatTime(message.timestamp)}</span>
                  {message.payloadSize != null ? <span>{formatBytes(message.payloadSize)}</span> : null}
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

function Section({ title, children }: { title: string; children: React.ReactNode }): JSX.Element {
  return (
    <section className="detail-section">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function HeadersTable({ headers }: { headers: Array<{ name: string; value: string }> }): JSX.Element {
  if (headers.length === 0) return <div className="empty-block">No headers captured.</div>;
  return (
    <div className="headers-table">
      {headers.map((header, index) => (
        <div className="header-row" key={`${header.name}:${index}`}>
          <span>{header.name}</span>
          <code>{header.value}</code>
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
  if (body == null || body.length === 0) return <div className="empty-block">No body captured.</div>;
  const pretty = prettyBody(body, props.base64Encoded);
  return (
    <div className="body-block">
      <div className="body-toolbar">
        <span>{props.base64Encoded ? "Base64 encoded" : props.encoding ?? "Text"}</span>
        <button type="button" onClick={() => void navigator.clipboard.writeText(body)}>
          <Download size={14} />
          Copy
        </button>
      </div>
      <pre>{pretty}</pre>
    </div>
  );
}

function StatusPill({ status, compact = false }: { status: RequestStatus; compact?: boolean }): JSX.Element {
  if (status.kind === "pending") {
    return <span className={`status-pill pending ${compact ? "compact" : ""}`}>Pending</span>;
  }
  if (status.kind === "failure") {
    return <span className={`status-pill failure ${compact ? "compact" : ""}`}>Failed</span>;
  }
  return (
    <span className={`status-pill ${status.code >= 400 ? "failure" : "success"} ${compact ? "compact" : ""}`}>
      {compact ? status.code : `${status.code} ${status.code >= 400 ? "Error" : "OK"}`}
    </span>
  );
}

async function refreshServers(
  client: NetworkClient,
  setState: React.Dispatch<React.SetStateAction<InspectorDataState>>,
  setSelectedServer: React.Dispatch<React.SetStateAction<ServerId | null>>
): Promise<void> {
  const servers = await client.listServers();
  setState((current) => ({ ...current, servers }));
  setSelectedServer((current) => pickSelectedServer(current, servers));
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
    const primary = parts.at(-1) ?? parsed.host;
    const secondary = parts.length > 1 ? `/${parts.slice(0, -1).join("/")}` : parsed.host;
    return { primary: `${primary}${parsed.search}`, secondary };
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

function formatDuration(startedAt: number, endedAt?: number): string {
  if (endedAt == null) return `Started ${formatTime(startedAt)}`;
  const ms = Math.max(0, endedAt - startedAt);
  if (ms < 1_000) return `${ms} ms`;
  return `${(ms / 1_000).toFixed(2)} s`;
}

function formatTime(value: number): string {
  return new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(value));
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}
