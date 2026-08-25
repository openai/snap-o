import { memo } from "react";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord } from "../../../network/cdp";
import type { InspectableApp, SnapOServer } from "../../../network/bridge-types";
import { OpenAppButton } from "../../app-inspector/components/OpenAppButton";
import type { AppLaunchControl } from "../../app-inspector/useAppLaunch";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { resolveDetailEmptyState } from "../lib/records";
import { isUnsupportedLegacyProtocolRequestSelection, unsupportedLegacyProtocolMessage } from "../lib/protocol";
import { RequestDetail } from "./RequestDetail";
import { WebSocketDetail } from "./WebSocketDetail";

export const DetailContent = memo(function DetailContent({
  client,
  record,
  servers,
  selectedServer,
  selectedApp,
  appLaunch,
  serverScopedItems,
  streamIsRetrying,
  uiState,
  onOpenDocs,
  onRetryResponseBody
}: {
  client: NetworkClient;
  record: InspectorRecord | null;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  selectedApp?: InspectableApp | null;
  appLaunch?: AppLaunchControl | null;
  serverScopedItems: number;
  streamIsRetrying: boolean;
  uiState: InspectorUiState;
  onOpenDocs(): void;
  onRetryResponseBody(): void;
}): JSX.Element {
  if (record == null) {
    const canOpenApp =
      selectedApp != null &&
      appLaunch != null &&
      serverScopedItems === 0 &&
      (!selectedServer?.isConnected || !selectedServer.hasAppInfo || streamIsRetrying);
    const empty = resolveDetailEmptyState({ servers, selectedServer, serverScopedItems, streamIsRetrying, canOpenApp });
    return (
      <EmptyState title={empty.title} body={empty.body} showDocsLink={empty.showDocsLink} onOpenDocs={onOpenDocs}>
        {canOpenApp ? <OpenAppButton app={selectedApp} launch={appLaunch} /> : null}
      </EmptyState>
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

  if (record.kind === "websocket") return <WebSocketDetail client={client} record={record} uiState={uiState} />;
  return (
    <RequestDetail
      client={client}
      record={record}
      uiState={uiState}
      isConnected={selectedServer?.isConnected === true}
      onRetryResponseBody={onRetryResponseBody}
    />
  );
});

function EmptyState({
  title,
  body,
  showDocsLink,
  onOpenDocs,
  children
}: {
  title: string;
  body: string | null;
  showDocsLink: boolean;
  onOpenDocs(): void;
  children?: React.ReactNode;
}): JSX.Element {
  return (
    <section className="empty-detail">
      <h1>{title}</h1>
      {body != null ? <p>{emptyStateBody(body)}</p> : null}
      {children}
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
