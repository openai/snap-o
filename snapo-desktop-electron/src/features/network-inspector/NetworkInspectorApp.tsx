import { DetailContent } from "./components/DetailPane";
import { Sidebar } from "./components/Sidebar";
import { useNetworkInspectorModel } from "./hooks/useNetworkInspectorModel";

export function NetworkInspectorApp(): JSX.Element {
  const model = useNetworkInspectorModel();

  return (
    <div className="app-shell">
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

      <main className="detail-pane">
        <DetailContent
          record={model.selectedRecord}
          servers={model.servers}
          selectedServer={model.selectedServer}
          serverScopedItems={model.serverRecordCount}
          uiState={model.uiState}
          onOpenDocs={model.openDocs}
        />
      </main>
    </div>
  );
}
