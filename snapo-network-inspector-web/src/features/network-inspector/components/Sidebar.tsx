import type { JSX } from "preact";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";
import { serverHasProtocolWarning } from "../lib/protocol";
import { ExclusionFilterControl } from "./ExclusionFilterControl";
import { RecordList } from "./RecordList";

export function Sidebar({
  selectedServer,
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
  selectedServer: SnapOServer | null;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  client: NetworkClient;
  onAddExclusionFilter(value: string): void;
  onRemoveExclusionFilter(filter: string): void;
  onRecordSelect(id: string): void;
}): JSX.Element {
  return (
    <aside className="sidebar">
      {serverHasProtocolWarning(selectedServer) ? <ProtocolWarning server={selectedServer} /> : null}
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
        isConnected={selectedServer?.isConnected === true}
      />
    </aside>
  );
}

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
