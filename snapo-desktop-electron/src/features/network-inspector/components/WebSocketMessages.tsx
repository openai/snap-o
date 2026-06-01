import { Inbox, Send } from "lucide-react";
import { memo } from "react";
import type { WebSocketMessageRecord } from "../../../network/cdp";
import { formatBytes, makeBodyPayload } from "../../../network/payload";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { formatTime } from "../lib/format";
import { InlineCopyButton, InlineTextToggle, PayloadView } from "./PayloadView";
import { HighlightText } from "./SearchHighlight";

export const WebSocketMessageCard = memo(function WebSocketMessageCard({
  message,
  storageKey,
  uiState,
  searchText
}: {
  message: WebSocketMessageRecord;
  storageKey: string;
  uiState: InspectorUiState;
  searchText: string;
}): JSX.Element {
  const preview = message.preview ?? "";
  const payload = makeBodyPayload({ body: preview, headers: [] });
  const prettyText = payload?.prettyText ?? null;
  const pretty = uiState.prettyEnabled(storageKey, prettyText != null);
  const displayText = pretty && prettyText != null ? prettyText : preview;
  const copyFeedback = useCopyFeedback(displayText);

  return (
    <div className="message-card">
      <div className="message-meta">
        {message.direction === "outgoing" ? (
          <Send size={10} className="message-direction outgoing" />
        ) : (
          <Inbox size={10} className="message-direction incoming" />
        )}
        {message.payloadSize == null ? null : (
          <span>
            <HighlightText text={formatBytes(message.payloadSize)} searchText={searchText} />
          </span>
        )}
        {message.enqueued == null ? null : (
          <span>
            <HighlightText text={message.enqueued ? "enqueued" : "immediate"} searchText={searchText} />
          </span>
        )}
        <span>{formatTime(message.timestamp)}</span>
        <span className="message-opcode">
          <HighlightText text={message.opcode} searchText={searchText} />
        </span>
        <span className="message-actions">
          {prettyText == null ? null : (
            <InlineTextToggle
              label={pretty ? "PRETTY" : "RAW"}
              onClick={() => uiState.setPrettyEnabled(storageKey, !pretty)}
            />
          )}
          {displayText.length === 0 ? null : (
            <InlineCopyButton copied={copyFeedback.copied} onCopy={copyFeedback.copy} iconOnly />
          )}
        </span>
      </div>
      {payload == null ? null : (
        <PayloadView
          payload={payload}
          storageKey={storageKey}
          uiState={uiState}
          showsToggle={false}
          showsCopyButton={false}
          prettyInitiallyExpanded={false}
          embedded
          searchText={searchText}
        />
      )}
    </div>
  );
});
