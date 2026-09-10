import type { JSX } from "preact";
import type { InspectableApp } from "../../network/bridge-types";
import { DetailContent } from "./components/DetailPane";
import type { AppLaunchControl } from "../app-inspector/useAppInspector";
import { Sidebar } from "./components/Sidebar";
import type { NetworkInspectorModel } from "./hooks/useNetworkInspectorModel";
import { usePersistentSplitPane } from "./hooks/usePersistentSplitPane";
import { useSearchHighlights } from "./hooks/useSearchHighlights";

export function NetworkInspectorApp({
  model,
  selectedApp = null,
  appLaunch
}: {
  model: NetworkInspectorModel;
  selectedApp?: InspectableApp | null;
  appLaunch?: AppLaunchControl | null;
}): JSX.Element {
  const {
    containerRef,
    sidebarWidth,
    minSidebarWidth,
    maxSidebarWidth,
    beginResize,
    continueResize,
    endResize,
    resizeWithKeyboard
  } = usePersistentSplitPane();
  useSearchHighlights(containerRef, model.searchText);

  return (
    <div
      className="app-shell"
      ref={containerRef}
      style={{ "--sidebar-width": `${sidebarWidth}px` } as JSX.CSSProperties}
    >
      <Sidebar
        selectedServer={model.selectedServer}
        exclusionFilters={model.exclusionFilters}
        hiddenRequestCount={model.hiddenRequestCount}
        records={model.visibleRecords}
        allRecords={model.allRecords}
        placeholder={model.sidebarPlaceholder}
        selectedRecordId={model.selectedRecordId}
        client={model.client}
        onAddExclusionFilter={model.addExclusionFilter}
        onRemoveExclusionFilter={model.removeExclusionFilter}
        onRecordSelect={model.selectRecord}
      />

      <div
        className="splitter"
        role="separator"
        aria-label="Resize request list"
        aria-orientation="vertical"
        aria-valuemin={minSidebarWidth}
        aria-valuemax={maxSidebarWidth}
        aria-valuenow={sidebarWidth}
        tabIndex={0}
        onPointerDown={beginResize}
        onPointerMove={continueResize}
        onPointerUp={endResize}
        onPointerCancel={endResize}
        onKeyDown={resizeWithKeyboard}
      />

      <main className="detail-pane">
        <DetailContent
          client={model.client}
          record={model.selectedRecord}
          servers={model.servers}
          selectedServer={model.selectedServer}
          selectedApp={selectedApp}
          appLaunch={appLaunch}
          serverScopedItems={model.serverRecordCount}
          streamIsRetrying={model.streamIsRetrying}
          uiState={model.uiState}
          onOpenDocs={model.openDocs}
          onRetryResponseBody={model.retryResponseBody}
        />
      </main>
    </div>
  );
}
