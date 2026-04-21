import { ArrowDownUp, Check, ChevronDown, Copy, Inbox, Send, Trash2 } from "lucide-react";
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
  type WebSocketMessageRecord,
  type WebSocketRecord
} from "./network/cdp";
import type { SnapOServer } from "./network/bridge-types";
import { buildHar, harFileName, makeCurlCommand, streamEventsRaw } from "./network/exporters";
import {
  bodyMetadata as payloadMetadata,
  dataUrlForImage,
  formatBytes,
  isImagePayload,
  makeBodyPayload,
  parseJsonNode,
  prettyJsonOrNull,
  type BodyPayload,
  type JsonNode
} from "./network/payload";

const docsUrl = "https://github.com/openai/snap-o/blob/main/docs/network-inspector.md";
const inspectorUiStorageKey = "snapo.networkInspector.ui.v1";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [selectedServer, setSelectedServer] = useState<ServerId | null>(null);
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const uiState = usePersistentInspectorUiState();

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

  const allRecords = useMemo(() => [...state.requests.values(), ...state.webSockets.values()], [state]);

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
  const hasClearableItems = allRecords.some((record) => record.status.kind !== "pending");

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
          allRecords={allRecords}
          placeholder={sidebarPlaceholder}
          selectedRecordId={selectedRecordId}
          onSelect={setSelectedRecordId}
          client={client}
        />
      </aside>

      <main className="detail-pane">
        <DetailContent
          record={selectedRecord}
          servers={state.servers}
          selectedServer={selectedServerModel}
          serverScopedItems={serverRecordCount}
          uiState={uiState}
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
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  onSelect: (id: string) => void;
  client: NetworkClient;
}): JSX.Element {
  const [menu, setMenu] = useState<ContextMenuState | null>(null);
  useEffect(() => {
    if (menu == null) return;
    const close = () => setMenu(null);
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", close);
    };
  }, [menu]);

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
            onContextMenu={(event) => {
              event.preventDefault();
              props.onSelect(id);
              setMenu({
                x: event.clientX,
                y: event.clientY,
                items: sidebarContextMenuItems(record, props.selectedRecordId, props.allRecords, props.client)
              });
            }}
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
      {menu == null ? null : <ContextMenu menu={menu} onClose={() => setMenu(null)} />}
    </div>
  );
}

function DetailContent(props: {
  record: InspectorRecord | null;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  serverScopedItems: number;
  uiState: PersistentInspectorUiState;
  onOpenDocs: () => void;
}): JSX.Element {
  if (props.record == null) {
    const empty = resolveDetailEmptyState(props);
    return (
      <EmptyState title={empty.title} body={empty.body} showDocsLink={empty.showDocsLink} onOpenDocs={props.onOpenDocs} />
    );
  }

  if (props.record.kind === "websocket") return <WebSocketDetail record={props.record} uiState={props.uiState} />;
  return <RequestDetail record={props.record} uiState={props.uiState} />;
}

function RequestDetail({ record, uiState }: { record: RequestRecord; uiState: PersistentInspectorUiState }): JSX.Element {
  const requestBody = makeBodyPayload({
    body: record.requestBody,
    headers: record.requestHeaders,
    encoding: record.requestBodyEncoding
  });
  const responseBody = makeBodyPayload({
    body: record.responseBody,
    headers: record.responseHeaders,
    base64Encoded: record.responseBodyBase64Encoded,
    totalBytes: record.encodedDataLength
  });
  const prefix = `request:${recordId(record)}`;
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
        <Section title="Request Headers" storageKey={`${prefix}:requestHeaders`} uiState={uiState}>
          <HeadersTable headers={record.requestHeaders} />
        </Section>
      )}
      {requestBody == null ? null : (
        <Section title="Request Body" meta={payloadMetadata(requestBody)} storageKey={`${prefix}:requestBody`} uiState={uiState}>
          <BodySection payload={requestBody} storageKey={`${prefix}:requestBody:payload`} uiState={uiState} />
        </Section>
      )}
      {record.status.kind === "pending" ? <div className="pending-response">Waiting for response...</div> : null}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers" storageKey={`${prefix}:responseHeaders`} uiState={uiState}>
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      {record.streamEvents.length > 0 ? (
        <Section title="Server-Sent Events" storageKey={`${prefix}:stream`} uiState={uiState} trailing={<SseCopyAllButton events={record.streamEvents} />}>
          <SseEventList events={record.streamEvents} storageKey={`${prefix}:stream`} uiState={uiState} />
        </Section>
      ) : null}
      {responseBody == null ? null : (
        <Section title="Response Body" meta={payloadMetadata(responseBody)} storageKey={`${prefix}:responseBody`} uiState={uiState}>
          <BodySection payload={responseBody} storageKey={`${prefix}:responseBody:payload`} uiState={uiState} />
        </Section>
      )}
    </div>
  );
}

function WebSocketDetail({ record, uiState }: { record: WebSocketRecord; uiState: PersistentInspectorUiState }): JSX.Element {
  const prefix = `websocket:${recordId(record)}`;
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
        <WebSocketCloseDetails record={record} />
      </header>
      {record.requestHeaders.length === 0 ? null : (
        <Section title="Request Headers" storageKey={`${prefix}:requestHeaders`} uiState={uiState}>
          <HeadersTable headers={record.requestHeaders} />
        </Section>
      )}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers" storageKey={`${prefix}:responseHeaders`} uiState={uiState}>
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      <Section title="Messages" storageKey={`${prefix}:messages`} uiState={uiState}>
        {record.messages.length === 0 ? (
          <div className="messages-empty">No messages yet</div>
        ) : (
          <div className="event-list">
            {record.messages.map((message) => (
              <WebSocketMessageCard
                key={message.id}
                message={message}
                storageKey={`${prefix}:message:${message.id}`}
                uiState={uiState}
              />
            ))}
          </div>
        )}
      </Section>
    </div>
  );
}

function Section({
  title,
  meta,
  storageKey,
  uiState,
  trailing,
  children
}: {
  title: string;
  meta?: string | null;
  storageKey: string;
  uiState: PersistentInspectorUiState;
  trailing?: React.ReactNode;
  children: React.ReactNode;
}): JSX.Element {
  const expanded = uiState.sectionExpanded(storageKey);
  return (
    <section className="detail-section">
      <div className="section-header-row">
        <button className="section-header" type="button" onClick={() => uiState.setSectionExpanded(storageKey, !expanded)}>
          <span className={expanded ? "triangle expanded" : "triangle"} />
          <span>{title}</span>
          {meta == null ? null : <span className="section-meta">{meta}</span>}
        </button>
        {trailing}
      </div>
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

function BodySection({ payload, storageKey, uiState }: {
  payload: BodyPayload;
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  if (isImagePayload(payload)) {
    return <ImagePreview payload={payload} />;
  }
  return (
    <PayloadView
      payload={payload}
      storageKey={storageKey}
      uiState={uiState}
      prettyInitiallyExpanded
    />
  );
}

function PayloadView({
  payload,
  storageKey,
  uiState,
  showsToggle = true,
  showsCopyButton = true,
  prettyInitiallyExpanded = true
}: {
  payload: BodyPayload;
  storageKey: string;
  uiState: PersistentInspectorUiState;
  showsToggle?: boolean;
  showsCopyButton?: boolean;
  prettyInitiallyExpanded?: boolean;
}): JSX.Element {
  const defaultPretty = payload.prettyText != null;
  const pretty = uiState.prettyEnabled(storageKey, defaultPretty);
  const displayText = pretty && payload.prettyText != null ? payload.prettyText : payload.rawText;
  const jsonRoot = useMemo(
    () => (pretty && payload.prettyText != null ? parseJsonNode(payload.prettyText) : null),
    [payload.prettyText, pretty]
  );
  const copyFeedback = useCopyFeedback(displayText);
  const hasToggle = showsToggle && payload.prettyText != null;
  const hasCopy = showsCopyButton && displayText.length > 0;

  return (
    <div className="payload-card">
      {hasToggle || hasCopy ? (
        <div className="payload-controls">
          {hasToggle ? (
            <InlineTextToggle
              label={pretty ? "PRETTY" : "RAW"}
              onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)}
            />
          ) : null}
          {hasCopy ? <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} /> : null}
        </div>
      ) : null}
      {payload.prettyText == null && payload.isLikelyJson ? (
        <div className="json-parse-hint">Unable to pretty print (invalid or truncated JSON)</div>
      ) : null}
      {jsonRoot == null ? (
        <pre>{displayText}</pre>
      ) : (
        <JsonOutline
          node={jsonRoot}
          storageKey={`${storageKey}:json`}
          uiState={uiState}
          initiallyExpanded={prettyInitiallyExpanded}
        />
      )}
    </div>
  );
}

function JsonOutline({
  node,
  storageKey,
  uiState,
  depth = 0,
  initiallyExpanded
}: {
  node: JsonNode;
  storageKey: string;
  uiState: PersistentInspectorUiState;
  depth?: number;
  initiallyExpanded: boolean;
}): JSX.Element {
  const expandable = node.children.length > 0;
  const rowKey = `${storageKey}:${node.key}`;
  const expanded = expandable ? uiState.jsonExpanded(rowKey, depth === 0 ? initiallyExpanded : false) : false;
  return (
    <div className="json-outline">
      <div className="json-row" style={{ paddingLeft: `${depth * 14}px` }}>
        {expandable ? (
          <button
            className="json-toggle"
            type="button"
            onClick={() => uiState.setJsonExpanded(rowKey, !expanded)}
            aria-label={expanded ? "Collapse JSON node" : "Expand JSON node"}
          >
            <span className={expanded ? "triangle expanded" : "triangle"} />
          </button>
        ) : (
          <span className="json-toggle-spacer" />
        )}
        <span className="json-key">{node.label}</span>
        {node.valuePreview == null ? null : <span className="json-preview">{node.valuePreview}</span>}
      </div>
      {expanded
        ? node.children.map((child) => (
            <JsonOutline
              key={child.key}
              node={child}
              storageKey={storageKey}
              uiState={uiState}
              depth={depth + 1}
              initiallyExpanded={false}
            />
          ))
        : null}
    </div>
  );
}

function ImagePreview({ payload }: { payload: BodyPayload }): JSX.Element | null {
  const dataUrl = dataUrlForImage(payload);
  const copyFeedback = useCopyFeedback("image");
  const saveFeedback = useCopyFeedback("save-image");
  if (dataUrl == null) return null;
  return (
    <div className="image-preview-card">
      <div className="image-preview-header">
        <span>Image preview</span>
        <span className="image-content-type">{payload.contentType?.toUpperCase() ?? ""}</span>
      </div>
      <div className="image-actions">
        <InlineCopyButton
          copied={copyFeedback.copied}
          label="Copy Image"
          onCopy={() => {
            copyFeedback.copyWithoutClipboard();
            void copyImageToClipboard(dataUrl, payload.contentType ?? "image/png");
          }}
        />
        <InlineTextToggle
          label={saveFeedback.copied ? "SAVED" : "SAVE AS..."}
          onClick={() => {
            saveFeedback.copyWithoutClipboard();
            downloadDataUrl(dataUrl, imageFileName(payload.contentType));
          }}
        />
      </div>
      <img className="image-preview" src={dataUrl} alt="" />
    </div>
  );
}

function SseCopyAllButton({ events }: { events: RequestRecord["streamEvents"] }): JSX.Element {
  const text = streamEventsRaw(events);
  const copyFeedback = useCopyFeedback(text);
  return (
    <button className="inline-action section-action" type="button" onClick={copyFeedback.copy} disabled={events.length === 0}>
      {copyFeedback.copied ? "Copied" : "Copy All"}
    </button>
  );
}

function SseEventList({
  events,
  storageKey,
  uiState
}: {
  events: RequestRecord["streamEvents"];
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  if (events.length === 0) return <div className="messages-empty">Awaiting events...</div>;
  return (
    <div className="event-list">
      {events.map((event) => (
        <SseEventCard key={event.sequence} event={event} storageKey={`${storageKey}:event:${event.sequence}`} uiState={uiState} />
      ))}
    </div>
  );
}

function SseEventCard({
  event,
  storageKey,
  uiState
}: {
  event: RequestRecord["streamEvents"][number];
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  const rawText = event.data ?? event.raw;
  const prettyText = prettyJsonOrNull(rawText);
  const pretty = uiState.prettyEnabled(storageKey, prettyText != null);
  const displayText = pretty && prettyText != null ? prettyText : rawText;
  const copyFeedback = useCopyFeedback(displayText);
  const payload = makeBodyPayload({ body: rawText, headers: [] });
  return (
    <div className="event-row">
      <div className="event-meta">
        <span>#{event.sequence}</span>
        <span>{formatTime(event.timestamp)}</span>
        {event.eventName ? <span className="event-name">{event.eventName}</span> : null}
        <span className="event-actions">
          {prettyText == null ? null : (
            <InlineTextToggle label={pretty ? "PRETTY" : "RAW"} onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)} />
          )}
          <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} />
        </span>
      </div>
      {payload == null ? <pre>{event.raw || "<empty>"}</pre> : (
        <PayloadView
          payload={{ ...payload, prettyText, isLikelyJson: prettyText != null || payload.isLikelyJson }}
          storageKey={`${storageKey}:payload`}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
        />
      )}
      {event.eventId == null || event.eventId.length === 0 ? null : (
        <div className="stream-event-metadata">Last-Event-ID: {event.eventId}</div>
      )}
    </div>
  );
}

function WebSocketMessageCard({
  message,
  storageKey,
  uiState
}: {
  message: WebSocketMessageRecord;
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  const preview = message.preview ?? "";
  const prettyText = prettyJsonOrNull(preview);
  const pretty = uiState.prettyEnabled(storageKey, prettyText != null);
  const displayText = pretty && prettyText != null ? prettyText : preview;
  const copyFeedback = useCopyFeedback(displayText);
  const payload = makeBodyPayload({ body: preview, headers: [] });
  return (
    <div className="message-card">
      <div className="message-meta">
        {message.direction === "outgoing" ? (
          <Send size={20} className="message-direction outgoing" />
        ) : (
          <Inbox size={20} className="message-direction incoming" />
        )}
        {message.payloadSize == null ? null : <span>{formatBytes(message.payloadSize)}</span>}
        {message.enqueued == null ? null : <span>{message.enqueued ? "enqueued" : "immediate"}</span>}
        <span>{formatTime(message.timestamp)}</span>
        <span className="message-opcode">{message.opcode}</span>
        <span className="message-actions">
          {prettyText == null ? null : (
            <InlineTextToggle label={pretty ? "PRETTY" : "RAW"} onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)} />
          )}
          {displayText.length === 0 ? null : <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} />}
        </span>
      </div>
      {payload == null ? null : (
        <PayloadView
          payload={{ ...payload, prettyText, isLikelyJson: prettyText != null || payload.isLikelyJson }}
          storageKey={`${storageKey}:payload`}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
        />
      )}
    </div>
  );
}

function WebSocketCloseDetails({ record }: { record: WebSocketRecord }): JSX.Element | null {
  if (record.status.kind !== "success" || record.endedAt == null) return null;
  const reason = record.closeReason;
  return (
    <div className="close-details">
      <div>Closed: {record.status.code}</div>
      {reason == null || reason.length === 0 ? null : <div>Reason: {reason}</div>}
    </div>
  );
}

function InlineTextToggle({ label, onClick }: { label: string; onClick: () => void }): JSX.Element {
  return (
    <button className="inline-text-toggle" type="button" onClick={onClick}>
      {label}
    </button>
  );
}

function InlineCopyButton({
  copied,
  onCopy,
  label = "Copy"
}: {
  copied: boolean;
  onCopy: () => void;
  label?: string;
}): JSX.Element {
  return (
    <button className="inline-action" type="button" onClick={onCopy}>
      {copied ? <Check size={14} /> : <Copy size={14} />}
      {copied ? "Copied" : label}
    </button>
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

interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
}

interface ContextMenuItem {
  label: string;
  action: () => void;
}

function ContextMenu({ menu, onClose }: { menu: ContextMenuState; onClose: () => void }): JSX.Element {
  return (
    <div className="context-menu" style={{ left: menu.x, top: menu.y }} onPointerDown={(event) => event.stopPropagation()}>
      {menu.items.map((item) => (
        <button
          className="context-menu-item"
          type="button"
          key={item.label}
          onClick={() => {
            item.action();
            onClose();
          }}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

function sidebarContextMenuItems(
  clicked: InspectorRecord,
  selectedRecordId: string | null,
  allRecords: InspectorRecord[],
  client: NetworkClient
): ContextMenuItem[] {
  const exportRecords = contextMenuExportSelection(clicked, selectedRecordId, allRecords);
  if (clicked.kind === "request") {
    return [
      { label: "Copy URL", action: () => void navigator.clipboard.writeText(clicked.url) },
      { label: "Copy as cURL", action: () => void copyCurl(client, clicked) },
      { label: "Export (sanitized)...", action: () => void exportAsHar(client, exportRecords) }
    ];
  }
  return [{ label: "Export (sanitized)...", action: () => void exportAsHar(client, exportRecords) }];
}

function contextMenuExportSelection(
  clicked: InspectorRecord,
  selectedRecordId: string | null,
  allRecords: InspectorRecord[]
): InspectorRecord[] {
  const selected = selectedRecordId == null ? null : allRecords.find((record) => recordId(record) === selectedRecordId) ?? null;
  if (selected == null || selected.kind !== clicked.kind || recordId(selected) === recordId(clicked)) return [clicked];
  return [selected, clicked];
}

async function copyCurl(client: NetworkClient, request: RequestRecord): Promise<void> {
  let hydrated = request;
  if (request.requestBody == null) {
    try {
      hydrated = applyRequestBodies(
        request,
        await client.loadBodies({
          deviceId: request.server.deviceId,
          socketName: request.server.socketName,
          requestId: request.requestId
        })
      );
    } catch {
      hydrated = request;
    }
  }
  await navigator.clipboard.writeText(makeCurlCommand(hydrated));
}

async function exportAsHar(client: NetworkClient, records: InspectorRecord[]): Promise<void> {
  if (records.length === 0) return;
  const hydrated = await Promise.all(
    records.map(async (record) => {
      if (record.kind !== "request" || (record.requestBody != null && record.responseBody != null)) return record;
      try {
        const bodies = await client.loadBodies({
          deviceId: record.server.deviceId,
          socketName: record.server.socketName,
          requestId: record.requestId
        });
        return applyRequestBodies(record, bodies);
      } catch {
        return record;
      }
    })
  );
  await client.saveFile({
    defaultPath: harFileName(hydrated.length),
    data: buildHar(hydrated),
    mimeType: "application/har+json"
  });
}

interface InspectorUiPreferences {
  sections: Record<string, boolean>;
  pretty: Record<string, boolean>;
  json: Record<string, boolean>;
}

interface PersistentInspectorUiState {
  sectionExpanded(key: string): boolean;
  setSectionExpanded(key: string, value: boolean): void;
  prettyEnabled(key: string, fallback: boolean): boolean;
  setPrettyEnabled(key: string, value: boolean): void;
  jsonExpanded(key: string, fallback: boolean): boolean;
  setJsonExpanded(key: string, value: boolean): void;
}

function usePersistentInspectorUiState(): PersistentInspectorUiState {
  const [prefs, setPrefs] = useState<InspectorUiPreferences>(loadInspectorUiPreferences);

  useEffect(() => {
    window.localStorage.setItem(inspectorUiStorageKey, JSON.stringify(prefs));
  }, [prefs]);

  return {
    sectionExpanded: (key) => prefs.sections[key] ?? true,
    setSectionExpanded: (key, value) => setPrefs((current) => ({ ...current, sections: { ...current.sections, [key]: value } })),
    prettyEnabled: (key, fallback) => prefs.pretty[key] ?? fallback,
    setPrettyEnabled: (key, value) => setPrefs((current) => ({ ...current, pretty: { ...current.pretty, [key]: value } })),
    jsonExpanded: (key, fallback) => prefs.json[key] ?? fallback,
    setJsonExpanded: (key, value) => setPrefs((current) => ({ ...current, json: { ...current.json, [key]: value } }))
  };
}

function loadInspectorUiPreferences(): InspectorUiPreferences {
  try {
    const raw = window.localStorage.getItem(inspectorUiStorageKey);
    if (raw == null) return emptyInspectorUiPreferences();
    const parsed = JSON.parse(raw) as Partial<InspectorUiPreferences>;
    return {
      sections: parsed.sections ?? {},
      pretty: parsed.pretty ?? {},
      json: parsed.json ?? {}
    };
  } catch {
    return emptyInspectorUiPreferences();
  }
}

function emptyInspectorUiPreferences(): InspectorUiPreferences {
  return { sections: {}, pretty: {}, json: {} };
}

function useCopyFeedback(text: string): { copied: boolean; copy: () => void; copyWithoutClipboard: () => void } {
  const [token, setToken] = useState(0);
  useEffect(() => {
    if (token === 0) return;
    const active = token;
    const timer = window.setTimeout(() => {
      setToken((current) => (current === active ? 0 : current));
    }, 1_000);
    return () => window.clearTimeout(timer);
  }, [token, text]);
  return {
    copied: token !== 0,
    copy: () => {
      void navigator.clipboard.writeText(text);
      setToken((current) => current + 1);
    },
    copyWithoutClipboard: () => setToken((current) => current + 1)
  };
}

async function copyImageToClipboard(dataUrl: string, mimeType: string): Promise<void> {
  const clipboardItem = window.ClipboardItem;
  if (clipboardItem == null) return;
  const response = await fetch(dataUrl);
  const blob = await response.blob();
  await navigator.clipboard.write([new clipboardItem({ [mimeType]: blob })]);
}

function downloadDataUrl(dataUrl: string, fileName: string): void {
  const anchor = document.createElement("a");
  anchor.href = dataUrl;
  anchor.download = fileName;
  anchor.style.display = "none";
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
}

function imageFileName(contentType: string | null): string {
  if (contentType?.startsWith("image/png") === true) return "image.png";
  if (contentType?.startsWith("image/jpeg") === true || contentType?.startsWith("image/jpg") === true) return "image.jpg";
  if (contentType?.startsWith("image/webp") === true) return "image.webp";
  if (contentType?.startsWith("image/gif") === true) return "image.gif";
  return "image";
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
