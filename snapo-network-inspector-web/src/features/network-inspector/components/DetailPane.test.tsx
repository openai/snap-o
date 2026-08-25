import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { InspectableApp, SnapOServer } from "../../../network/bridge-types";
import type { NetworkClient } from "../../../network/client";
import { useInspectorUiState } from "../hooks/useInspectorUiState";
import { DetailContent } from "./DetailPane";

const app: InspectableApp = {
  id: "phone:pid:10",
  name: "Demo",
  packageName: "com.example.demo",
  deviceId: "phone",
  deviceDisplayTitle: "Phone",
  inspectors: []
};
const server: SnapOServer = {
  server: app.id,
  deviceId: app.deviceId,
  socketName: "snapo_network_10",
  deviceDisplayTitle: "Phone",
  displayName: "Demo",
  isConnected: true,
  hasAppInfo: true,
  isProtocolNewerThanSupported: false,
  isProtocolOlderThanSupported: false
};

function render(
  selectedServer: SnapOServer | null,
  count = 0,
  retrying = false,
  selectedApp: InspectableApp | null = app,
  launchPending = false,
  canOpenApp = true
) {
  const client = { openApp: vi.fn(async () => {}) } as unknown as NetworkClient;
  function View() {
    return (
      <DetailContent
        client={client}
        record={null}
        servers={selectedServer ? [selectedServer] : []}
        selectedServer={selectedServer}
        selectedApp={selectedApp}
        appLaunch={canOpenApp ? { pending: launchPending, error: null, open: vi.fn() } : null}
        serverScopedItems={count}
        streamIsRetrying={retrying}
        uiState={useInspectorUiState()}
        onOpenDocs={() => {}}
        onRetryResponseBody={() => {}}
      />
    );
  }
  return renderToStaticMarkup(<View />);
}

describe("network waiting action", () => {
  it.each([null, { ...server, hasAppInfo: false }, { ...server, isConnected: false }])(
    "offers to open the selected app while its server is unavailable",
    (selectedServer) => expect(render(selectedServer)).toContain("Open Demo")
  );

  it("offers to open the app while retrying its first network stream", () => {
    expect(render(server, 0, true)).toContain("Open Demo");
  });

  it.each([false, true])("omits the manual opening hint when the launch action is available", (pending) => {
    const markup = render({ ...server, hasAppInfo: false }, 0, false, app, pending);
    expect(markup).toContain("Waiting for connection");
    expect(markup).not.toContain("Open the app on your device to connect.");
  });

  it("keeps the manual opening hint when the launch action is unavailable", () => {
    const markup = render({ ...server, hasAppInfo: false }, 0, false, app, false, false);
    expect(markup).toContain("Open the app on your device to connect.");
    expect(markup).not.toContain("Open Demo");
  });

  it("replaces the action with progress without changing the waiting text", () => {
    const markup = render({ ...server, hasAppInfo: false }, 0, false, app, true);
    expect(markup).toContain("Waiting for connection");
    expect(markup).toContain('role="progressbar"');
    expect(markup).not.toContain('class="inspector-open-app"');
  });

  it("hides the action once connected, with retained records, or without a selected app", () => {
    expect(render(server)).not.toContain("Open Demo");
    expect(render({ ...server, isConnected: false }, 1, true)).not.toContain("Open Demo");
    expect(render(null, 0, false, null)).not.toContain("inspector-open-app");
  });
});
