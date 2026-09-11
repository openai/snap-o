import type { JSX } from "preact";
import { useMemo } from "preact/hooks";
import type { ToolContentClient } from "../../../network/client";
import type { RequestRecord } from "../../../network/cdp";
import { makeBodyPayload } from "../../../network/payload";
import { streamEventsRaw } from "../../../network/exporters";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { ToolUiState } from "../hooks/useToolUiState";
import { formatTime } from "../lib/format";
import { InlineCopyButton, InlineTextToggle, PayloadView } from "./PayloadView";

const emptyStreamMessages = {
  Pending: "Waiting for response",
  Streaming: "Awaiting events",
  Closed: "No events received",
  Offline: "No events received"
};

export type SseStatus = keyof typeof emptyStreamMessages;

export function SseCopyAllButton({
  client,
  events
}: {
  client: ToolContentClient;
  events: RequestRecord["streamEvents"];
}): JSX.Element {
  const text = useMemo(() => streamEventsRaw(events), [events]);
  const copyFeedback = useCopyFeedback(client, text);
  return (
    <button
      className="inline-action section-action"
      type="button"
      onClick={copyFeedback.copy}
      disabled={events.length === 0}
    >
      {copyFeedback.copied ? "Copied" : "Copy All"}
    </button>
  );
}

export function SseEventList({
  client,
  events,
  closed,
  status,
  storageKey,
  uiState
}: {
  client: ToolContentClient;
  events: RequestRecord["streamEvents"];
  closed?: RequestRecord["streamClosed"];
  status: SseStatus;
  storageKey: string;
  uiState: ToolUiState;
}): JSX.Element {
  return useMemo(() => {
    return (
      <div className="event-list">
        {events.length === 0 ? (
          <div className="messages-empty">{emptyStreamMessages[status]}</div>
        ) : (
          events.map((event) => (
            <SseEventCard
              key={event.sequence}
              client={client}
              event={event}
              storageKey={`${storageKey}:event:${event.sequence}`}
              uiState={uiState}
            />
          ))
        )}
        {closed == null ? null : <StreamCloseMessage closed={closed} />}
      </div>
    );
  }, [client, events, closed, status, storageKey, uiState]);
}

function SseEventCard({
  client,
  event,
  storageKey,
  uiState
}: {
  client: ToolContentClient;
  event: RequestRecord["streamEvents"][number];
  storageKey: string;
  uiState: ToolUiState;
}): JSX.Element {
  const rawText = event.data ?? event.raw;
  const payload = useMemo(() => makeBodyPayload({ body: rawText, headers: [] }), [rawText]);
  const prettyText = payload?.prettyText ?? null;
  const pretty = uiState.prettyEnabled(storageKey, prettyText != null);
  const displayText = pretty && prettyText != null ? prettyText : rawText;
  const copyFeedback = useCopyFeedback(client, displayText);

  return useMemo(
    () => (
      <div className="event-row">
        <div className="event-meta">
          <div className="event-info">
            <span>#{event.sequence}</span>
            <span>{formatTime(event.timestamp)}</span>
            {event.eventName ? <span className="event-name">{event.eventName}</span> : null}
          </div>
          <span className="event-actions">
            {prettyText == null ? null : (
              <InlineTextToggle
                label={pretty ? "PRETTY" : "RAW"}
                onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)}
              />
            )}
            <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} iconOnly />
          </span>
        </div>
        {payload == null ? (
          <pre>{event.raw || "<empty>"}</pre>
        ) : (
          <PayloadView
            client={client}
            payload={payload}
            storageKey={storageKey}
            uiState={uiState}
            showsToggle={false}
            showsCopyButton={false}
            prettyInitiallyExpanded={false}
            embedded
          />
        )}
        <SseEventMetadata event={event} />
      </div>
    ),
    [client, event, storageKey, uiState, payload, prettyText, pretty, copyFeedback]
  );
}

function SseEventMetadata({ event }: { event: RequestRecord["streamEvents"][number] }): JSX.Element | null {
  if (event.comment == null && event.lastEventId == null && event.retryMillis == null) return null;
  return (
    <div className="stream-event-metadata">
      {event.comment == null ? null : <div>Comment: {event.comment}</div>}
      {event.lastEventId == null ? null : <div>Last-Event-ID: {event.lastEventId}</div>}
      {event.retryMillis == null ? null : <div>Retry: {event.retryMillis} ms</div>}
    </div>
  );
}

function StreamCloseMessage({ closed }: { closed: NonNullable<RequestRecord["streamClosed"]> }): JSX.Element | null {
  if (closed.reason === "completed") return null;
  const message = closed.message?.trim() || (closed.reason === "error" ? "Connection error." : closed.reason);
  return (
    <div className="stream-close-message" role="status">
      Stream closed: {message}
    </div>
  );
}
