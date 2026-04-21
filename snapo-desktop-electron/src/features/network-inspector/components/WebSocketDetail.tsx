import { memo } from "react";
import { recordId, type WebSocketRecord } from "../../../network/cdp";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";
import { formatTiming } from "../lib/format";
import { HeadersTable, Section } from "./Section";
import { FailureMessage, StatusBadge } from "./Status";
import { WebSocketMessageCard } from "./WebSocketMessages";

export const WebSocketDetail = memo(function WebSocketDetail({
  record,
  uiState
}: {
  record: WebSocketRecord;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
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
        <Section title="Request Headers" storageKey={`${prefix}:requestHeaders`} uiState={uiState} initiallyExpanded={false}>
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
});

function WebSocketCloseDetails({ record }: { record: WebSocketRecord }): JSX.Element | null {
  const closeRequested = record.closeRequested;
  const closing = record.closing;
  const closed = record.closed;
  if (closeRequested == null && closing == null && closed == null) return null;

  return (
    <div className="close-details">
      {closeRequested == null ? null : (
        <>
          <div>
            Close requested: {closeRequested.code} • {capitalize(closeRequested.initiated)} •{" "}
            {closeRequested.accepted ? "accepted" : "not accepted"}
          </div>
          {closeRequested.reason == null || closeRequested.reason.length === 0 ? null : (
            <div>Reason: {closeRequested.reason}</div>
          )}
        </>
      )}
      {closing == null ? null : (
        <>
          <div>Closing handshake: {closing.code}</div>
          {closing.reason == null || closing.reason.length === 0 ? null : <div>Reason: {closing.reason}</div>}
        </>
      )}
      {closed == null ? null : (
        <>
          <div>Closed: {closed.code}</div>
          {closed.reason == null || closed.reason.length === 0 ? null : <div>Reason: {closed.reason}</div>}
        </>
      )}
    </div>
  );
}

function capitalize(value: string): string {
  if (value.length === 0) return value;
  return `${value.charAt(0).toUpperCase()}${value.slice(1)}`;
}
