import { BodySearchContext } from "./components/SearchablePayload";
import type { JSX } from "preact";
import { DetailContent } from "./components/DetailPane";
import { Sidebar } from "./components/Sidebar";
import type { NetworkToolModel } from "./hooks/useNetworkToolModel";
import { usePersistentSplitPane } from "./hooks/usePersistentSplitPane";
import { useSearchHighlights } from "./hooks/useSearchHighlights";

export function NetworkToolApp({ model }: { model: NetworkToolModel }): JSX.Element {
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
        searchStatus={model.searchStatus}
        searchStatusDetail={model.searchStatusDetail}
        bodyMatches={model.bodyMatches}
        isConnected={model.isConnected}
        exclusionFilters={model.exclusionFilters}
        hiddenRequestCount={model.hiddenRequestCount}
        records={model.visibleRecords}
        allRecords={model.allRecords}
        sortNewestFirst={model.sortNewestFirst}
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
        <BodySearchContext.Provider value={model.searchText}>
          <DetailContent
            client={model.client}
            record={model.selectedRecord}
            isConnected={model.isConnected}
            totalItems={model.totalItems}
            streamIsRetrying={model.streamIsRetrying}
            uiState={model.uiState}
            onRetryResponseBody={model.retryResponseBody}
          />
        </BodySearchContext.Provider>
      </main>
    </div>
  );
}
