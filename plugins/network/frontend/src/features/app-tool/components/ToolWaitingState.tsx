import type { JSX } from "preact";
import { LoadingSpinner } from "../../../components/LoadingSpinner";

export function ToolWaitingState({ error }: { error?: string | null }): JSX.Element {
  const label = "Waiting for tool";
  return (
    <div className="tool-loading">
      <div className="tool-loading-status" role="status" aria-label={label}>
        <span>{label}</span>
        <LoadingSpinner size={20} />
      </div>
      {error ? (
        <p className="tool-open-error" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  );
}
