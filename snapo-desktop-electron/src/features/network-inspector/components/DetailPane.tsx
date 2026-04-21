import { memo } from "react";
import type { InspectorRecord } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";
import { resolveDetailEmptyState } from "../lib/records";
import { RequestDetail } from "./RequestDetail";
import { WebSocketDetail } from "./WebSocketDetail";

export const DetailContent = memo(function DetailContent({
  record,
  servers,
  selectedServer,
  serverScopedItems,
  uiState,
  onOpenDocs
}: {
  record: InspectorRecord | null;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  serverScopedItems: number;
  uiState: PersistentInspectorUiState;
  onOpenDocs(): void;
}): JSX.Element {
  if (record == null) {
    const empty = resolveDetailEmptyState({ servers, selectedServer, serverScopedItems });
    return <EmptyState title={empty.title} body={empty.body} showDocsLink={empty.showDocsLink} onOpenDocs={onOpenDocs} />;
  }

  if (record.kind === "websocket") return <WebSocketDetail record={record} uiState={uiState} />;
  return <RequestDetail record={record} uiState={uiState} />;
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
      <p>{body}</p>
      {showDocsLink ? (
        <button className="text-button" type="button" onClick={onOpenDocs}>
          Read the developer guide
        </button>
      ) : null}
    </section>
  );
}
