import type { InspectorRecord, RequestStatus } from "../../../network/cdp";
import { statusDisplayName, statusToneClass } from "../lib/format";
import { recordShowsActiveIndicator } from "../lib/records";
import { HighlightText } from "./SearchHighlight";

export function StatusView({ record, searchText = "" }: { record: InspectorRecord; searchText?: string }): JSX.Element {
  if (recordShowsActiveIndicator(record)) return <span className="active-indicator">●</span>;
  const status = record.status;
  if (status.kind === "pending") return <span className="pending-spinner" aria-label="Pending" />;
  if (status.kind === "failure")
    return (
      <span className="row-status status-error">
        <HighlightText text="Error" searchText={searchText} />
      </span>
    );
  return (
    <span className={`row-status ${statusToneClass(status.code)}`}>
      <HighlightText text={String(status.code)} searchText={searchText} />
    </span>
  );
}

export function StatusBadge({
  record,
  searchText = ""
}: {
  record: InspectorRecord;
  searchText?: string;
}): JSX.Element {
  if (record.kind === "request" && record.streamEvents.length > 0 && record.streamClosed == null) {
    return (
      <span className="status-label status-streaming">
        <HighlightText text="Streaming" searchText={searchText} />
      </span>
    );
  }
  const status = record.status;
  if (status.kind === "pending")
    return (
      <span className="status-label status-pending">
        <HighlightText text="Pending" searchText={searchText} />
      </span>
    );
  if (status.kind === "failure")
    return (
      <span className="status-label status-error">
        <HighlightText text="Error" searchText={searchText} />
      </span>
    );
  return (
    <span className={`status-label ${statusToneClass(status.code)}`}>
      <HighlightText text={statusDisplayName(status.code)} searchText={searchText} />
    </span>
  );
}

export function FailureMessage({
  status,
  searchText = ""
}: {
  status: RequestStatus;
  searchText?: string;
}): JSX.Element | null {
  if (status.kind !== "failure" || status.message == null || status.message.trim().length === 0) return null;
  return (
    <div className="failure-message">
      <HighlightText text={`Error: ${status.message}`} searchText={searchText} />
    </div>
  );
}
