import type { CSSProperties } from "react";
import { DetailContent } from "./components/DetailPane";
import { Sidebar } from "./components/Sidebar";
import { useNetworkInspectorModel } from "./hooks/useNetworkInspectorModel";
import { usePersistentSplitPane } from "./hooks/usePersistentSplitPane";

export function NetworkInspectorApp(): JSX.Element {
  const model = useNetworkInspectorModel();
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
        onServerChange={model.selectServer}
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
          record={model.selectedRecord}
          servers={model.servers}
          selectedServer={model.selectedServer}
          serverScopedItems={model.serverRecordCount}
          searchText={model.searchText}
          uiState={model.uiState}
          onOpenDocs={model.openDocs}
        />
      </main>
    </div>
  );
}
