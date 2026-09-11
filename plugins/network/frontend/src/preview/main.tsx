import { render, type JSX } from "preact";
import { useState } from "preact/hooks";
import { RequestDetail } from "../features/network-tool/components/RequestDetail";
import { useToolUiState } from "../features/network-tool/hooks/useToolUiState";
import { previewClient } from "./client";
import { previewRequests } from "./requests";
import "../styles.css";
import "./preview.css";

function RequestDetailPreview(): JSX.Element {
  const [selectedId, setSelectedId] = useState(
    () => new URLSearchParams(window.location.search).get("request") ?? previewRequests[0].record.requestId
  );
  const uiState = useToolUiState();
  const { record } = previewRequests.find((sample) => sample.record.requestId === selectedId) ?? previewRequests[0];

  return (
    <div className="request-preview">
      <nav className="preview-toolbar" aria-label="Preview controls">
        <label htmlFor="preview-request">Mock request</label>
        <select
          id="preview-request"
          value={record.requestId}
          onChange={(event) => {
            const requestId = event.currentTarget.value;
            setSelectedId(requestId);
            const url = new URL(window.location.href);
            url.searchParams.set("request", requestId);
            window.history.replaceState(null, "", url);
          }}
        >
          {previewRequests.map((sample) => (
            <option key={sample.record.requestId} value={sample.record.requestId}>
              {sample.label}
            </option>
          ))}
        </select>
        <span>Synthetic data</span>
      </nav>
      <main className="detail-pane">
        <RequestDetail
          key={record.requestId}
          client={previewClient}
          record={record}
          uiState={uiState}
          onRetryResponseBody={() => {}}
        />
      </main>
    </div>
  );
}

render(<RequestDetailPreview />, document.getElementById("root") as HTMLElement);
