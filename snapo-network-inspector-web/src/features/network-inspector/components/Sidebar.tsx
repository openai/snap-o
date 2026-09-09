import type { JSX } from "preact";
import { RefreshCw } from "lucide-preact";
import type { NetworkClient } from "../../../network/client";
import type { InspectorRecord } from "../../../network/cdp";
import type { SnapOServer } from "../../../network/bridge-types";
import { serverHasProtocolWarning } from "../lib/protocol";
import { ExclusionFilterControl } from "./ExclusionFilterControl";
import { RecordList } from "./RecordList";

export function Sidebar({
  selectedServer,
  replacementServer,
  exclusionFilters,
  hiddenRequestCount,
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  client,
  onReplacementServerClick,
  onAddExclusionFilter,
  onRemoveExclusionFilter,
  onRecordSelect
}: {
  selectedServer: SnapOServer | null;
  replacementServer: SnapOServer | null;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  client: NetworkClient;
  onReplacementServerClick(server: SnapOServer): void;
  onAddExclusionFilter(value: string): void;
  onRemoveExclusionFilter(filter: string): void;
  onRecordSelect(id: string): void;
}): JSX.Element {
  return (
    <aside className="sidebar">
      {replacementServer == null ? null : (
        <div className="server-picker-frame">
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
        </div>
      )}
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
