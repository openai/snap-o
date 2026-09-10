import type { JSX } from "preact";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord } from "../../../network/cdp";
import type { InspectorMetadata } from "../../app-inspector/useInspectorMetadata";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { resolveDetailEmptyState } from "../lib/records";
import { hasProtocolWarning, unsupportedProtocolMessage } from "../lib/protocol";
import { RequestDetail } from "./RequestDetail";
import { WebSocketDetail } from "./WebSocketDetail";

export function DetailContent({
  client,
  record,
  metadata,
  isConnected,
  totalItems,
  streamIsRetrying,
  uiState,
  onRetryResponseBody
}: {
  client: NetworkClient;
  record: InspectorRecord | null;
  metadata: InspectorMetadata | null;
  isConnected: boolean;
  totalItems: number;
  streamIsRetrying: boolean;
  uiState: InspectorUiState;
  onRetryResponseBody(): void;
}): JSX.Element {
  if (record == null) {
    const empty =
      metadata && hasProtocolWarning(metadata.protocolVersion)
        ? { title: "This app uses an unsupported protocol", body: unsupportedProtocolMessage(metadata.protocolVersion) }
        : resolveDetailEmptyState({ isConnected, totalItems, streamIsRetrying });
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
