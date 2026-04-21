import { Inbox, Send } from "lucide-react";
import { memo } from "react";
import type { WebSocketMessageRecord } from "../../../network/cdp";
import { formatBytes, makeBodyPayload, prettyJsonOrNull } from "../../../network/payload";
import { useCopyFeedback } from "../hooks/useCopyFeedback";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";
import { formatTime } from "../lib/format";
import { InlineCopyButton, InlineTextToggle, PayloadView } from "./PayloadView";

export const WebSocketMessageCard = memo(function WebSocketMessageCard({
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
});
