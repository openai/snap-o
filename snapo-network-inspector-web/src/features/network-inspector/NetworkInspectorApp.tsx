import { type CSSProperties } from "react";
import type {
  AppInspectorKind,
  AppInspectorOption,
  InspectableApp,
  SelectedAppInspector
} from "../../network/bridge-types";
import { DetailContent } from "./components/DetailPane";
import { Sidebar } from "./components/Sidebar";
import type { NetworkInspectorModel } from "./hooks/useNetworkInspectorModel";
import { usePersistentSplitPane } from "./hooks/usePersistentSplitPane";
import { useSearchHighlights } from "./hooks/useSearchHighlights";

export function NetworkInspectorApp({
  model,
  inspectorApps = [],
  inspectorSelection = null,
  selectedApp = null,
  preferredKind,
  onInspectorSelect
}: {
  model: NetworkInspectorModel;
  inspectorApps?: InspectableApp[];
  inspectorSelection?: SelectedAppInspector | null;
  selectedApp?: InspectableApp | null;
  preferredKind?: AppInspectorKind | null;
  onInspectorSelect?(app: InspectableApp, option?: AppInspectorOption): void;
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
    <div className="app-shell" ref={containerRef} style={{ "--sidebar-width": `${sidebarWidth}px` } as CSSProperties}>
      <Sidebar
        servers={model.servers}
        selectedServer={model.selectedServer}
        replacementServer={model.replacementServer}
        searchText={model.searchText}
        exclusionFilters={model.exclusionFilters}
        hiddenRequestCount={model.hiddenRequestCount}
        sortNewestFirst={model.sortNewestFirst}
        hasClearableItems={model.hasClearableItems}
        records={model.visibleRecords}
        allRecords={model.allRecords}
        placeholder={model.sidebarPlaceholder}
        selectedRecordId={model.selectedRecordId}
        client={model.client}
        showsServerPicker={!model.client.usesNativeServerPicker}
        showsInlineToolbar={!model.client.usesNativeServerPicker}
        onServerChange={model.selectServer}
        inspectorApps={inspectorApps}
        inspectorSelection={inspectorSelection}
        selectedApp={selectedApp}
        preferredKind={preferredKind}
        onInspectorSelect={onInspectorSelect}
        onReplacementServerClick={(server) => {
          const app = inspectorApps.find((candidate) =>
            candidate.inspectors.some(
              (option) =>
                option.kind === "network" &&
                option.server.deviceId === server.deviceId &&
                option.server.socketName === server.socketName
            )
          );
          const option = app?.inspectors.find((candidate) => candidate.kind === "network");
          if (app && option && onInspectorSelect) onInspectorSelect(app, option);
          else model.selectReplacementServer(server);
        }}
        onSearchTextChange={model.setSearchText}
        onAddExclusionFilter={model.addExclusionFilter}
        onRemoveExclusionFilter={model.removeExclusionFilter}
        onToggleSortOrder={model.toggleSortOrder}
        onClearCompleted={model.clearCompletedRecords}
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
