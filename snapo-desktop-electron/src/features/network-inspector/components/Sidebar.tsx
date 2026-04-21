import { ArrowDownUp, Trash2 } from "lucide-react";
import { memo } from "react";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord, ServerId } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";
import { RecordList } from "./RecordList";
import { ServerSelect } from "./ServerPicker";

export const Sidebar = memo(function Sidebar({
  servers,
  selectedServer,
  replacementServer,
  searchText,
  sortNewestFirst,
  hasClearableItems,
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  client,
  onServerChange,
  onReplacementServerClick,
  onSearchTextChange,
  onToggleSortOrder,
  onClearCompleted,
  onRecordSelect
}: {
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  replacementServer: SnapOServer | null;
  searchText: string;
  sortNewestFirst: boolean;
  hasClearableItems: boolean;
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  client: NetworkClient;
  onServerChange(server: ServerId | null): void;
  onReplacementServerClick(server: SnapOServer): void;
  onSearchTextChange(value: string): void;
  onToggleSortOrder(): void;
  onClearCompleted(): void;
  onRecordSelect(id: string): void;
}): JSX.Element {
  return (
    <aside className="sidebar">
      <div className="server-picker-frame">
        <ServerSelect servers={servers} selectedServer={selectedServer} onChange={onServerChange} />
        {replacementServer == null ? null : (
          <button className="replacement-banner" type="button" onClick={() => onReplacementServerClick(replacementServer)}>
            <span>
              <span className="replacement-title">New process available</span>
              <span className="replacement-detail">
                {replacementServer.pid == null ? "Tap to switch process" : `PID ${replacementServer.pid}`}
              </span>
            </span>
          </button>
        )}
      </div>

      <div className="filter-frame">
        <div className="search-row">
          <input
            value={searchText}
            onChange={(event) => onSearchTextChange(event.target.value)}
            placeholder="Filter by URL"
            aria-label="Filter by URL"
          />
        </div>

        <div className="toolbar-action-group">
          <button
            className="toolbar-icon-button"
            type="button"
            title="Toggle sort order"
            aria-label="Toggle sort order"
            onClick={onToggleSortOrder}
          >
            <ArrowDownUp size={16} className={sortNewestFirst ? "sort-icon newest" : "sort-icon"} />
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

      <RecordList
        records={records}
        allRecords={allRecords}
        placeholder={placeholder}
        selectedRecordId={selectedRecordId}
        onSelect={onRecordSelect}
        client={client}
      />
    </aside>
  );
});
