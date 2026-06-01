import { memo } from "react";
import type { InspectorRecord } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { resolveDetailEmptyState } from "../lib/records";
import { isUnsupportedLegacyProtocolRequestSelection, unsupportedLegacyProtocolMessage } from "../lib/protocol";
import { RequestDetail } from "./RequestDetail";
import { WebSocketDetail } from "./WebSocketDetail";

export const DetailContent = memo(function DetailContent({
  record,
  servers,
  selectedServer,
  serverScopedItems,
  searchText,
  uiState,
  onOpenDocs
}: {
  record: InspectorRecord | null;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  serverScopedItems: number;
  searchText: string;
  uiState: InspectorUiState;
  onOpenDocs(): void;
}): JSX.Element {
  if (record == null) {
    const empty = resolveDetailEmptyState({ servers, selectedServer, serverScopedItems });
    return (
      <EmptyState title={empty.title} body={empty.body} showDocsLink={empty.showDocsLink} onOpenDocs={onOpenDocs} />
    );
  }

  if (isUnsupportedLegacyProtocolRequestSelection(record, selectedServer)) {
    return (
      <EmptyState
        title="This app server uses an unsupported protocol"
        body={unsupportedLegacyProtocolMessage(selectedServer)}
        showDocsLink={false}
        onOpenDocs={onOpenDocs}
      />
    );
  }

  if (record.kind === "websocket") return <WebSocketDetail record={record} uiState={uiState} searchText={searchText} />;
  return <RequestDetail record={record} uiState={uiState} searchText={searchText} />;
});

function EmptyState({
  title,
  body,
  showDocsLink,
  onOpenDocs
}: {
  title: string;
  body: string;
  showDocsLink: boolean;
  onOpenDocs(): void;
}): JSX.Element {
  return (
    <section className="empty-detail">
      <h1>{title}</h1>
      <p>{emptyStateBody(body)}</p>
      {showDocsLink ? (
        <button className="text-button" type="button" onClick={onOpenDocs}>
          Read the developer guide
        </button>
      ) : null}
    </section>
  );
}

function emptyStateBody(body: string): React.ReactNode {
  const marker = "`com.openai.snapo`";
  if (!body.includes(marker)) return body;
  const [before, after] = body.split(marker, 2);
  return (
    <>
      {before}
      <code>com.openai.snapo</code>
      {after}
    </>
  );
}
