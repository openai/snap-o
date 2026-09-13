import type { JSX } from "preact";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import type { ToolUiState } from "../hooks/useToolUiState";
import { resolveDetailEmptyState } from "../lib/records";
import { RequestDetail } from "./RequestDetail";
import { WebSocketDetail } from "./WebSocketDetail";

export function DetailContent({
  client,
  record,
  isConnected,
  totalItems,
  streamIsRetrying,
  uiState,
  onRetryResponseBody
}: {
  client: NetworkClient;
  record: ToolRecord | null;
  isConnected: boolean;
  totalItems: number;
  streamIsRetrying: boolean;
  uiState: ToolUiState;
  onRetryResponseBody(): void;
}): JSX.Element {
  if (record == null) {
    const empty = resolveDetailEmptyState({ isConnected, totalItems, streamIsRetrying });
    return (
      <section className="empty-detail">
        <h1>{empty.title}</h1>
        <p>{empty.body}</p>
      </section>
    );
  }
  if (record.kind === "websocket") return <WebSocketDetail client={client} record={record} uiState={uiState} />;
  return (
    <RequestDetail
      client={client}
      record={record}
      uiState={uiState}
      isConnected={isConnected}
      onRetryResponseBody={onRetryResponseBody}
    />
  );
}
