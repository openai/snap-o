import { memo } from "react";
import type { RequestRecord } from "../../../network/cdp";
import { makeBodyPayload } from "../../../network/payload";
import { streamEventsRaw } from "../../../network/exporters";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { formatTime } from "../lib/format";
import { InlineCopyButton, InlineTextToggle, PayloadView } from "./PayloadView";
import { HighlightText } from "./SearchHighlight";

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
  uiState,
  searchText
}: {
  events: RequestRecord["streamEvents"];
  closed?: RequestRecord["streamClosed"];
  storageKey: string;
  uiState: InspectorUiState;
  searchText: string;
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
            searchText={searchText}
          />
        ))
      )}
      {closed == null ? null : <StreamClosedInfo closed={closed} searchText={searchText} />}
    </div>
  );
});

const SseEventCard = memo(function SseEventCard({
  event,
  storageKey,
  uiState,
  searchText
}: {
  event: RequestRecord["streamEvents"][number];
  storageKey: string;
  uiState: InspectorUiState;
  searchText: string;
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
        {event.eventName ? (
          <span className="event-name">
            <HighlightText text={event.eventName} searchText={searchText} />
          </span>
        ) : null}
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
        <pre>
          <HighlightText text={event.raw || "<empty>"} searchText={searchText} />
        </pre>
      ) : (
        <PayloadView
          payload={payload}
          storageKey={storageKey}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
          searchText={searchText}
        />
      )}
      <SseEventMetadata event={event} searchText={searchText} />
    </div>
  );
});

function SseEventMetadata({
  event,
  searchText
}: {
  event: RequestRecord["streamEvents"][number];
  searchText: string;
}): JSX.Element | null {
  if (event.comment == null && event.eventId == null && event.lastEventId == null && event.retryMillis == null)
    return null;
  return (
    <div className="stream-event-metadata">
      {event.comment == null ? null : (
        <div>
          <HighlightText text={`Comment: ${event.comment}`} searchText={searchText} />
        </div>
      )}
      {event.eventId == null ? null : (
        <div>
          <HighlightText text={`Event-ID: ${event.eventId}`} searchText={searchText} />
        </div>
      )}
      {event.lastEventId == null ? null : (
        <div>
          <HighlightText text={`Last-Event-ID: ${event.lastEventId}`} searchText={searchText} />
        </div>
      )}
      {event.retryMillis == null ? null : (
        <div>
          <HighlightText text={`Retry: ${event.retryMillis} ms`} searchText={searchText} />
        </div>
      )}
    </div>
  );
}

function StreamClosedInfo({
  closed,
  searchText
}: {
  closed: NonNullable<RequestRecord["streamClosed"]>;
  searchText: string;
}): JSX.Element {
  return (
    <div className="stream-closed-info">
      <div>
        <HighlightText
          text={`Stream closed (${closed.reason}) at ${formatTime(closed.timestamp)}`}
          searchText={searchText}
        />
      </div>
      {closed.message == null || closed.message.length === 0 ? null : (
        <div>
          <HighlightText text={`Message: ${closed.message}`} searchText={searchText} />
        </div>
      )}
      <div>
        <HighlightText
          text={`Total events: ${closed.totalEvents ?? 0} • Total bytes: ${closed.totalBytes ?? 0}`}
          searchText={searchText}
        />
      </div>
    </div>
  );
}
