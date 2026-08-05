import { RefreshCw, SortAsc, SortDesc, Trash2 } from "lucide-react";
import { memo } from "react";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord, ServerId } from "../../../network/cdp";
import type {
  AppInspectorOption,
  InspectableApp,
  SelectedAppInspector,
  SnapOServer
} from "../../../network/bridge-types";
import { AppInspectorPicker } from "../../app-inspector/components/AppInspectorPicker";
import { serverHasProtocolWarning } from "../lib/protocol";
import { ExclusionFilterControl } from "./ExclusionFilterControl";
import { RecordList } from "./RecordList";
import { ServerSelect } from "./ServerPicker";

export const Sidebar = memo(function Sidebar({
  servers,
  selectedServer,
  replacementServer,
  searchText,
  exclusionFilters,
  hiddenRequestCount,
  sortNewestFirst,
  hasClearableItems,
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  client,
  inspectorApps,
  inspectorSelection,
  showsServerPicker,
  showsInlineToolbar,
  onServerChange,
  onInspectorSelect,
  onReplacementServerClick,
  onSearchTextChange,
  onAddExclusionFilter,
  onRemoveExclusionFilter,
  onToggleSortOrder,
  onClearCompleted,
  onRecordSelect
}: {
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  replacementServer: SnapOServer | null;
  searchText: string;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  sortNewestFirst: boolean;
  hasClearableItems: boolean;
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  client: NetworkClient;
  inspectorApps?: InspectableApp[];
  inspectorSelection?: SelectedAppInspector | null;
  showsServerPicker: boolean;
  showsInlineToolbar: boolean;
  onServerChange(server: ServerId | null): void;
  onInspectorSelect?(app: InspectableApp, option: AppInspectorOption): void;
  onReplacementServerClick(server: SnapOServer): void;
  onSearchTextChange(value: string): void;
  onAddExclusionFilter(value: string): void;
  onRemoveExclusionFilter(filter: string): void;
  onToggleSortOrder(): void;
  onClearCompleted(): void;
  onRecordSelect(id: string): void;
}): JSX.Element {
  const SortIcon = sortNewestFirst ? SortDesc : SortAsc;
  const sortLabel = sortNewestFirst ? "newest first" : "oldest first";

  return (
    <aside className={showsInlineToolbar ? "sidebar" : "sidebar sidebar-without-inline-toolbar"}>
      {showsServerPicker || replacementServer != null ? (
        <div className="server-picker-frame">
          {showsServerPicker ? (
            inspectorApps && onInspectorSelect ? (
              <AppInspectorPicker
                apps={inspectorApps}
                selection={inspectorSelection ?? null}
                onSelect={onInspectorSelect}
              />
            ) : (
              <ServerSelect servers={servers} selectedServer={selectedServer} onChange={onServerChange} />
            )
          ) : null}
          {replacementServer == null ? null : (
            <button
              className="replacement-banner"
              type="button"
              onClick={() => onReplacementServerClick(replacementServer)}
            >
              <span>
                <span className="replacement-title">New process available</span>
                <span className="replacement-detail">
                  {replacementServer.pid == null ? "Tap to switch process" : `PID ${replacementServer.pid}`}
                </span>
              </span>
              <RefreshCw size={20} aria-hidden="true" />
            </button>
          )}
        </div>
      ) : null}

      {serverHasProtocolWarning(selectedServer) ? <ProtocolWarning server={selectedServer} /> : null}

      {showsInlineToolbar ? (
        <div className="filter-frame">
          <div className="search-row">
            <input
              value={searchText}
              onChange={(event) => onSearchTextChange(event.target.value)}
              placeholder="Filter by keyword"
              aria-label="Filter by keyword"
            />
          </div>

          <div className="toolbar-action-group">
            <button
              className="toolbar-icon-button"
              type="button"
              title={`Sorted ${sortLabel}`}
              aria-label={`Sorted ${sortLabel}. Toggle sort order`}
              onClick={onToggleSortOrder}
            >
              <SortIcon size={16} />
            </button>
            <button
              className="toolbar-icon-button"
              type="button"
              title="Clear completed"
              aria-label="Clear completed"
              disabled={!hasClearableItems}
              onClick={onClearCompleted}
            >
              <Trash2 size={16} />
            </button>
          </div>
        </div>
      ) : null}

      <ExclusionFilterControl
        exclusionFilters={exclusionFilters}
        hiddenRequestCount={hiddenRequestCount}
        onAddFilter={onAddExclusionFilter}
        onRemoveFilter={onRemoveExclusionFilter}
      />

      <RecordList
        records={records}
        allRecords={allRecords}
        placeholder={placeholder}
        selectedRecordId={selectedRecordId}
        onSelect={onRecordSelect}
        onAddExclusionFilter={onAddExclusionFilter}
        client={client}
      />
    </aside>
  );
});

function ProtocolWarning({ server }: { server: SnapOServer }): JSX.Element {
  return (
    <div className="protocol-warning">
      <div className="protocol-warning-title">
        {server.protocolVersion == null
          ? "Incompatible protocol version"
          : `Incompatible protocol version ${server.protocolVersion}`}
      </div>
      <div className="protocol-warning-body">
        {server.isProtocolOlderThanSupported
          ? "This Android build is using an older protocol than this Network Inspector supports."
          : "This Android build may be newer than the Network Inspector understands."}
      </div>
    </div>
  );
}
