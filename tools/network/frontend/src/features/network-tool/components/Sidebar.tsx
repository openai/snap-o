import type { JSX } from "preact";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import { ExclusionFilterControl } from "./ExclusionFilterControl";
import { RecordList } from "./RecordList";

export function Sidebar({
  isConnected,
  exclusionFilters,
  hiddenRequestCount,
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  client,
  onAddExclusionFilter,
  onRemoveExclusionFilter,
  onRecordSelect
}: {
  isConnected: boolean;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  records: ToolRecord[];
  allRecords: ToolRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  client: NetworkClient;
  onAddExclusionFilter(value: string): void;
  onRemoveExclusionFilter(filter: string): void;
  onRecordSelect(id: string): void;
}): JSX.Element {
  return (
    <aside className="sidebar">
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
        isConnected={isConnected}
      />
    </aside>
  );
}
