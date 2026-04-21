import { memo } from "react";
import type { RequestRecord } from "../../../network/cdp";
import { makeBodyPayload, prettyJsonOrNull } from "../../../network/payload";
import { streamEventsRaw } from "../../../network/exporters";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";
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
    <button className="inline-action section-action" type="button" onClick={copyFeedback.copy} disabled={events.length === 0}>
      {copyFeedback.copied ? "Copied" : "Copy All"}
    </button>
  );
});

export const SseEventList = memo(function SseEventList({
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
});

const SseEventCard = memo(function SseEventCard({
  event,
  storageKey,
  uiState
}: {
  event: RequestRecord["streamEvents"][number];
  storageKey: string;
  uiState: PersistentInspectorUiState;
}): JSX.Element {
  const parsedDataPayload = parseSsePayload(event.data);
  const parsedPayload = parsedDataPayload ?? parseSsePayload(event.raw);
  const rawText = parsedPayload?.data ?? event.data ?? event.raw;
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
      {payload == null ? (
        <pre>{event.raw || "<empty>"}</pre>
      ) : (
        <PayloadView
          payload={{ ...payload, prettyText, isLikelyJson: prettyText != null || payload.isLikelyJson }}
          storageKey={storageKey}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
        />
      )}
      {parsedDataPayload?.lastEventId == null ? null : (
        <div className="stream-event-metadata">Last-Event-ID: {parsedDataPayload.lastEventId}</div>
      )}
    </div>
  );
});

interface ParsedSsePayload {
  data: string | null;
  lastEventId: string | null;
}

function parseSsePayload(text: string | null | undefined): ParsedSsePayload | null {
  if (text == null || text.length === 0) return null;

  let sawSseField = false;
  let lastEventId: string | null = null;
  const dataLines: string[] = [];

  for (const line of text.split(/\r?\n/u)) {
    if (line.length === 0 || line.startsWith(":")) continue;

    const separatorIndex = line.indexOf(":");
    const field = separatorIndex === -1 ? line : line.slice(0, separatorIndex);
    const rawValue = separatorIndex === -1 ? "" : line.slice(separatorIndex + 1);
    const value = rawValue.startsWith(" ") ? rawValue.slice(1) : rawValue;

    if (field === "data") {
      sawSseField = true;
      dataLines.push(value);
    } else if (field === "id") {
      sawSseField = true;
      lastEventId = value;
    } else if (field === "event" || field === "retry") {
      sawSseField = true;
    }
  }

  if (!sawSseField) return null;
  return {
    data: dataLines.length === 0 ? null : dataLines.join("\n"),
    lastEventId
  };
}
