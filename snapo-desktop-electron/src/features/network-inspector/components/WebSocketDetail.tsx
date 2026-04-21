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
  if (record.status.kind !== "success" || record.endedAt == null) return null;
  const reason = record.closeReason;
  return (
    <div className="close-details">
      <div>Closed: {record.status.code}</div>
      {reason == null || reason.length === 0 ? null : <div>Reason: {reason}</div>}
    </div>
  );
}
