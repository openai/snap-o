import type { JSX } from "preact";
import { LoadingSpinner } from "../../../components/LoadingSpinner";
import type { ToolContentClient } from "../../../network/client";
import type { ResponseBodyLoadError } from "../../../network/bridge-types";
import type { BodyPayload } from "../../../network/payload";
import type { ToolUiState } from "../hooks/useToolUiState";
import { BodySection } from "./PayloadView";

export function ResponseBodyContent({
  client,
  payload,
  loading,
  error,
  isConnected,
  storageKey,
  uiState,
  onRetry
}: {
  client: ToolContentClient;
  payload: BodyPayload | null;
  loading: boolean;
  error?: ResponseBodyLoadError | null;
  isConnected: boolean;
  storageKey: string;
  uiState: ToolUiState;
  onRetry?(): void;
}): JSX.Element {
  if (payload != null)
    return <BodySection client={client} payload={payload} storageKey={storageKey} uiState={uiState} />;
  if (!isConnected && (loading || error === "failed")) {
    return (
      <div className="body-load-message" role="status">
        Response body isn’t cached on this Mac.
      </div>
    );
  }
  if (error != null) {
    return (
      <div className="body-load-message" role="status">
        <span>
          {error === "unavailable"
            ? "This response is no longer available. Try making the request again."
            : "Couldn’t load the response. Try again."}
        </span>
        {error === "failed" && onRetry ? (
          <button className="text-button" type="button" onClick={onRetry}>
            Retry
          </button>
        ) : null}
      </div>
    );
  }
  if (!loading) return <div className="body-load-message">No response body.</div>;
  return (
    <div className="payload-card">
      <div className="body-loading" role="status">
        <LoadingSpinner size={14} />
        <span>Loading</span>
      </div>
    </div>
  );
}
