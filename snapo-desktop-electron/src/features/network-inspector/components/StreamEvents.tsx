import { memo } from "react";
import type { RequestRecord } from "../../../network/cdp";
import { makeBodyPayload } from "../../../network/payload";
import { streamEventsRaw } from "../../../network/exporters";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { formatTime } from "../lib/format";
import { InlineCopyButton, InlineTextToggle, PayloadView } from "./PayloadView";

export const SseCopyAllButton = memo(function SseCopyAllButton({
  events
}: {
  events: RequestRecord["streamEvents"];
}): JSX.Element {
  const text = streamEventsRaw(events);
  const copyFeedback = useCopyFeedback(text);
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
});

export const SseEventList = memo(function SseEventList({
  events,
  closed,
  storageKey,
  uiState
}: {
  events: RequestRecord["streamEvents"];
  closed?: RequestRecord["streamClosed"];
  storageKey: string;
  uiState: InspectorUiState;
}): JSX.Element {
  return (
    <div className="event-list">
      {events.length === 0 ? (
        <div className="messages-empty">Awaiting events...</div>
      ) : (
        events.map((event) => (
          <SseEventCard
            key={event.sequence}
            event={event}
            storageKey={`${storageKey}:event:${event.sequence}`}
            uiState={uiState}
          />
        ))
      )}
      {closed == null ? null : <StreamClosedInfo closed={closed} />}
    </div>
  );
});

const SseEventCard = memo(function SseEventCard({
  event,
  storageKey,
  uiState
}: {
  event: RequestRecord["streamEvents"][number];
  storageKey: string;
  uiState: InspectorUiState;
}): JSX.Element {
  const rawText = event.data ?? event.raw;
  const payload = makeBodyPayload({ body: rawText, headers: [] });
  const prettyText = payload?.prettyText ?? null;
  const pretty = uiState.prettyEnabled(storageKey, prettyText != null);
  const displayText = pretty && prettyText != null ? prettyText : rawText;
  const copyFeedback = useCopyFeedback(displayText);

  return (
    <div className="event-row">
      <div className="event-meta">
        <span>#{event.sequence}</span>
        <span>{formatTime(event.timestamp)}</span>
        {event.eventName ? <span className="event-name">{event.eventName}</span> : null}
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
          payload={payload}
          storageKey={storageKey}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
        />
      )}
      <SseEventMetadata event={event} />
    </div>
  );
});

function SseEventMetadata({ event }: { event: RequestRecord["streamEvents"][number] }): JSX.Element | null {
  if (event.comment == null && event.eventId == null && event.lastEventId == null && event.retryMillis == null)
    return null;
  return (
    <div className="stream-event-metadata">
      {event.comment == null ? null : <div>Comment: {event.comment}</div>}
      {event.eventId == null ? null : <div>Event-ID: {event.eventId}</div>}
      {event.lastEventId == null ? null : <div>Last-Event-ID: {event.lastEventId}</div>}
      {event.retryMillis == null ? null : <div>Retry: {event.retryMillis} ms</div>}
    </div>
  );
}

function StreamClosedInfo({ closed }: { closed: NonNullable<RequestRecord["streamClosed"]> }): JSX.Element {
  return (
    <div className="stream-closed-info">
      <div>
        Stream closed ({closed.reason}) at {formatTime(closed.timestamp)}
      </div>
      {closed.message == null || closed.message.length === 0 ? null : <div>Message: {closed.message}</div>}
      <div>
        Total events: {closed.totalEvents ?? 0} • Total bytes: {closed.totalBytes ?? 0}
      </div>
    </div>
  );
}
