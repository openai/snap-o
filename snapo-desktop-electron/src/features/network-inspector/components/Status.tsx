import type { InspectorRecord, RequestStatus } from "../../../network/cdp";
import { statusDisplayName, statusToneClass } from "../lib/format";
import { recordShowsActiveIndicator } from "../lib/records";

export function StatusView({ record }: { record: InspectorRecord }): JSX.Element {
  if (recordShowsActiveIndicator(record)) return <span className="active-indicator">●</span>;
  const status = record.status;
  if (status.kind === "pending") return <span className="pending-spinner" aria-label="Pending" />;
  if (status.kind === "failure") return <span className="row-status status-error">Error</span>;
  return <span className={`row-status ${statusToneClass(status.code)}`}>{status.code}</span>;
}

export function StatusBadge({ record }: { record: InspectorRecord }): JSX.Element {
  if (record.kind === "request" && record.streamEvents.length > 0 && record.streamClosed == null) {
    return <span className="status-label status-streaming">Streaming</span>;
  }
  const status = record.status;
  if (status.kind === "pending") return <span className="status-label status-pending">Pending</span>;
  if (status.kind === "failure") return <span className="status-label status-error">Error</span>;
  return <span className={`status-label ${statusToneClass(status.code)}`}>{statusDisplayName(status.code)}</span>;
}

export function FailureMessage({ status }: { status: RequestStatus }): JSX.Element | null {
  if (status.kind !== "failure" || status.message == null || status.message.trim().length === 0) return null;
  return <div className="failure-message">Error: {status.message}</div>;
}
