// @vitest-environment jsdom
import { render as renderInto } from "preact";
import { act } from "preact/test-utils";
import { renderToStaticMarkup } from "preact-render-to-string";
import { describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import { useToolUiState } from "../hooks/useToolUiState";
import { DetailContent } from "./DetailPane";
import { BodySection } from "./PayloadView";
import { makeBodyPayload } from "../../../network/payload";
import type { ToolContentClient } from "../../../network/client";

function render(isConnected = true, totalItems = 0, streamIsRetrying = false) {
  function View() {
    return (
      <DetailContent
        client={{} as NetworkClient}
        record={null}
        isConnected={isConnected}
        totalItems={totalItems}
        streamIsRetrying={streamIsRetrying}
        uiState={useToolUiState()}
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
    expect(markup).not.toContain("tool-open-app");
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
});

describe("image export", () => {
  it.each([true, false])("saves decoded image bytes and shows feedback only on success (%s)", async (saved) => {
    const saveFile = vi.fn<ToolContentClient["saveFile"]>().mockResolvedValue(saved);
    const client = { copyText: vi.fn(async () => {}), saveFile };
    const payload = makeBodyPayload({
      body: "AA H/\n",
      headers: [{ name: "Content-Type", value: "image/png" }],
      base64Encoded: true
    })!;
    function View() {
      return <BodySection client={client} payload={payload} storageKey="image" uiState={useToolUiState()} />;
    }
    const container = document.createElement("div");
    document.body.append(container);
    try {
      await act(() => renderInto(<View />, container));
      const button = container.querySelector<HTMLButtonElement>('button[aria-label="Save Image As..."]')!;
      await act(async () => button.click());
      const { name, data } = saveFile.mock.calls[0][0];
      expect(name).toBe("image.png");
      expect(data.type).toBe("image/png");
      const buffer = await new Promise<ArrayBuffer>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result as ArrayBuffer);
        reader.onerror = () => reject(reader.error);
        reader.readAsArrayBuffer(data);
      });
      expect([...new Uint8Array(buffer)]).toEqual([0, 1, 255]);
      expect(button.getAttribute("aria-label")).toBe(saved ? "Saved" : "Save Image As...");
    } finally {
      await act(() => renderInto(null, container));
      container.remove();
    }
  });
});
