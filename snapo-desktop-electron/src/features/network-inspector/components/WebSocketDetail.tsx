import { memo } from "react";
import { recordId, type WebSocketRecord } from "../../../network/cdp";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { useAdaptiveTimingText } from "../hooks/useAdaptiveTimingText";
import { HeadersTable, Section } from "./Section";
import { HighlightText } from "./SearchHighlight";
import { FailureMessage, StatusBadge } from "./Status";
import { WebSocketMessageCard } from "./WebSocketMessages";

export const WebSocketDetail = memo(function WebSocketDetail({
  record,
  uiState,
  searchText
}: {
  record: WebSocketRecord;
  uiState: InspectorUiState;
  searchText: string;
}): JSX.Element {
  const prefix = `websocket:${recordId(record)}`;
  const timingText = useAdaptiveTimingText(record.startedAt, record.endedAt, record.status);
  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="detail-method">
            <HighlightText text={record.method} searchText={searchText} />
          </span>
          <h1>
            <HighlightText text={record.url} searchText={searchText} />
          </h1>
        </div>
        <div className="detail-meta">
          <StatusBadge record={record} searchText={searchText} />
          <span>{timingText}</span>
        </div>
        <FailureMessage status={record.status} searchText={searchText} />
        <WebSocketCloseDetails record={record} searchText={searchText} />
      </header>
      {record.requestHeaders.length === 0 ? null : (
        <Section
          title="Request Headers"
          storageKey={`${prefix}:requestHeaders`}
          uiState={uiState}
          initiallyExpanded={false}
        >
          <HeadersTable headers={record.requestHeaders} searchText={searchText} />
        </Section>
      )}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers" storageKey={`${prefix}:responseHeaders`} uiState={uiState}>
          <HeadersTable headers={record.responseHeaders} searchText={searchText} />
        </Section>
      )}
      <Section title="Messages" storageKey={`${prefix}:messages`} uiState={uiState}>
        {record.messages.length === 0 ? (
          <div className="messages-empty">No messages yet</div>
        ) : (
          <div className="message-list">
            {record.messages.map((message) => (
              <WebSocketMessageCard
                key={message.id}
                message={message}
                storageKey={`${prefix}:message:${message.id}`}
                uiState={uiState}
                searchText={searchText}
              />
            ))}
          </div>
        )}
      </Section>
    </div>
  );
});

function WebSocketCloseDetails({
  record,
  searchText
}: {
  record: WebSocketRecord;
  searchText: string;
}): JSX.Element | null {
  const closeRequested = record.closeRequested;
  const closing = record.closing;
  const closed = record.closed;
  if (closeRequested == null && closing == null && closed == null) return null;

  return (
    <div className="close-details">
      {closeRequested == null ? null : (
        <>
          <div>
            <HighlightText
              text={`Close requested: ${closeRequested.code} • ${capitalize(closeRequested.initiated)} • ${
                closeRequested.accepted ? "accepted" : "not accepted"
              }`}
              searchText={searchText}
            />
          </div>
          {closeRequested.reason == null || closeRequested.reason.length === 0 ? null : (
            <div>
              <HighlightText text={`Reason: ${closeRequested.reason}`} searchText={searchText} />
            </div>
          )}
        </>
      )}
      {closing == null ? null : (
        <>
          <div>
            <HighlightText text={`Closing handshake: ${closing.code}`} searchText={searchText} />
          </div>
          {closing.reason == null || closing.reason.length === 0 ? null : (
            <div>
              <HighlightText text={`Reason: ${closing.reason}`} searchText={searchText} />
            </div>
          )}
        </>
      )}
      {closed == null ? null : (
        <>
          <div>
            <HighlightText text={`Closed: ${closed.code}`} searchText={searchText} />
          </div>
          {closed.reason == null || closed.reason.length === 0 ? null : (
            <div>
              <HighlightText text={`Reason: ${closed.reason}`} searchText={searchText} />
            </div>
          )}
        </>
      )}
    </div>
  );
}

function capitalize(value: string): string {
  if (value.length === 0) return value;
  return `${value.charAt(0).toUpperCase()}${value.slice(1)}`;
}
