import { renderToStaticMarkup } from "preact-render-to-string";
import { describe, expect, it } from "vitest";
import type { NetworkClient } from "../../../network/client";
import { useInspectorUiState } from "../hooks/useInspectorUiState";
import { DetailContent } from "./DetailPane";

function render(isConnected = true, totalItems = 0, streamIsRetrying = false, protocolVersion = 3) {
  function View() {
    return (
      <DetailContent
        client={{} as NetworkClient}
        record={null}
        metadata={{ name: "Demo", packageName: "com.example.demo", protocolVersion, processIdentity: "boot:20:123" }}
        isConnected={isConnected}
        totalItems={totalItems}
        streamIsRetrying={streamIsRetrying}
        uiState={useInspectorUiState()}
        onRetryResponseBody={() => {}}
      />
    );
  }
  return renderToStaticMarkup(<View />);
}

describe("network empty state", () => {
  it("waits for a disconnected app without duplicating the native launch control", () => {
    const markup = render(false);
    expect(markup).toContain("Waiting for connection");
    expect(markup).toContain("Open the app on your device to connect.");
    expect(markup).not.toContain("inspector-open-app");
  });
  it("shows progress while retrying the first stream", () => {
    expect(render(true, 0, true)).toContain("Reconnecting");
  });
  it("waits for network activity once connected", () => {
    expect(render()).toContain("No activity for this app yet");
  });
  it("keeps retained records browsable while disconnected", () => {
    expect(render(false, 1, true)).toContain("Select a record");
  });
  it.each([0, 2, 4])("explains an unsupported protocol v%s", (version) => {
    const markup = render(true, 0, false, version);
    expect(markup).toContain(`App reports protocol v${version}`);
    expect(markup).toContain("Update Snap-O and the Android library together.");
  });
});
