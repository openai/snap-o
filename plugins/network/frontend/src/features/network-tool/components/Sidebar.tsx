import type { JSX } from "preact";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import type { PluginMetadata } from "../../app-tool/usePluginMetadata";
import { hasProtocolWarning, supportedProtocolVersion } from "../lib/protocol";
import { ExclusionFilterControl } from "./ExclusionFilterControl";
import { RecordList } from "./RecordList";

export function Sidebar({
  metadata,
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
  metadata: PluginMetadata | null;
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
      {metadata && hasProtocolWarning(metadata.protocolVersion) ? (
        <ProtocolWarning protocolVersion={metadata.protocolVersion} />
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
        isConnected={isConnected}
      />
    </aside>
  );
}

function ProtocolWarning({ protocolVersion }: { protocolVersion: number }): JSX.Element {
  return (
    <div className="protocol-warning">
      <div className="protocol-warning-title">Incompatible protocol version {protocolVersion}</div>
      <div className="protocol-warning-body">
        {protocolVersion < supportedProtocolVersion
          ? "This Android build is using an older protocol than this Network Tool supports."
          : "This Android build may be newer than the Network Tool understands."}
      </div>
    </div>
  );
}
