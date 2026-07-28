import { useEffect, type CSSProperties } from "react";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "../../network/bridge-types";
import { DetailContent } from "./components/DetailPane";
import { Sidebar } from "./components/Sidebar";
import { useNetworkInspectorModel } from "./hooks/useNetworkInspectorModel";
import { usePersistentSplitPane } from "./hooks/usePersistentSplitPane";
import { useSearchHighlights } from "./hooks/useSearchHighlights";

export function NetworkInspectorApp({
  inspectorApps = [],
  inspectorSelection = null,
  onInspectorSelect
}: {
  inspectorApps?: InspectableApp[];
  inspectorSelection?: SelectedAppInspector | null;
  onInspectorSelect?(app: InspectableApp, option: AppInspectorOption): void;
}): JSX.Element {
  const model = useNetworkInspectorModel();
  const { selectServer } = model;
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

  useEffect(() => {
    if (inspectorSelection?.kind !== "network") return;
    selectServer(inspectorSelection.server);
  }, [inspectorSelection, selectServer]);

  return (
    <div className="app-shell" ref={containerRef} style={{ "--sidebar-width": `${sidebarWidth}px` } as CSSProperties}>
      <Sidebar
        servers={model.servers}
        selectedServer={model.selectedServer}
        replacementServer={model.replacementServer}
        searchText={model.searchText}
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
        onInspectorSelect={onInspectorSelect}
        onReplacementServerClick={model.selectReplacementServer}
        onSearchTextChange={model.setSearchText}
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
        />
      </main>
    </div>
  );
}
