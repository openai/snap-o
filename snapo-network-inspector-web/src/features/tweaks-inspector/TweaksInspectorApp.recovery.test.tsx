// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SelectedAppInspector, TweakList, TweakStreamEvent } from "../../network/bridge-types";
import type { NetworkClient } from "../../network/client";
import { TweaksInspectorApp } from "./TweaksInspectorApp";

const selection: SelectedAppInspector = {
  appId: "phone:pid:10",
  kind: "tweaks",
  protocolVersion: 4,
  server: { deviceId: "phone", socketName: "snapo_tweaks_10" }
};
const response: TweakList = {
  tweaks: [{ name: "Demo title", type: "string", value: "Recovered", default: "Default" }]
};
const modifiedResponse: TweakList = {
  tweaks: [{ name: "Demo title", type: "string", value: "Changed", default: "Default", modified: true }]
};
const connectionError = new Error("Could not connect to the server.");

describe("Tweaks connection recovery", () => {
  let root: Root;
  let container: HTMLDivElement;
  let client: NetworkClient;
  let receive: (event: TweakStreamEvent) => void;
  let reset: () => void;

  beforeEach(() => {
    vi.useFakeTimers();
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    client = {
      usesNativeServerPicker: true,
      openApp: vi.fn(async () => {}),
      listTweaks: vi.fn(async () => response),
      startTweakStream: vi.fn(async () => ({ streamId: "stream-1" })),
      stopTweakStream: vi.fn(async () => {}),
      onTweaksChanged: vi.fn((callback) => {
        receive = callback;
        return () => {};
      }),
      updateTweaks: vi.fn(async () => ({ tweaks: [] })),
      invokeTweakAction: vi.fn(async () => {}),
      onNativeTweaksReset: vi.fn((callback) => {
        reset = callback;
        return () => {};
      }),
      nativeTweaksStateChanged: vi.fn()
    } as unknown as NetworkClient;
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    vi.useRealTimers();
  });

  async function render(selected = selection, isConnected = true) {
    await act(async () =>
      root.render(
        <TweaksInspectorApp
          client={client}
          apps={[]}
          selectedApp={{
            id: selected.appId,
            name: "Demo",
            packageName: "com.example.demo",
            deviceId: selected.server.deviceId,
            deviceDisplayTitle: "Phone",
            inspectors: [selected]
          }}
          selection={selected}
          appLaunch={{
            pending: false,
            error: null,
            open: () => void client.openApp!({ deviceId: selected.server.deviceId, packageName: "com.example.demo" })
          }}
          isConnected={isConnected}
          onSelect={() => {}}
        />
      )
    );
  }

  it.each([true, false])("shows status text while loading with native picker %s", async (usesNativeServerPicker) => {
    Object.assign(client, { usesNativeServerPicker });
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    const status = container.querySelector('[role="status"]');
    expect(status?.textContent).toBe("Waiting for inspector");
    expect(status?.querySelector("svg")).toBeNull();
    expect(container.querySelector(".inspector-open-app")).not.toBeNull();
    expect(container.querySelector(".tweaks-inspector-toolbar") != null).toBe(!usesNativeServerPicker);

    await act(async () => finish(response));
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
  });

  it("retries a failed initial request without changing the selected inspector", async () => {
    vi.mocked(client.listTweaks).mockRejectedValueOnce(connectionError);
    await render();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain(connectionError.message);
    expect(client.startTweakStream).not.toHaveBeenCalled();
    const openButton = container.querySelector<HTMLButtonElement>(".inspector-open-app")!;
    expect(openButton.textContent).toBe("Open Demo");
    await act(async () => openButton.click());
    expect(client.openApp).toHaveBeenCalledExactlyOnceWith({ deviceId: "phone", packageName: "com.example.demo" });

    await act(async () => vi.advanceTimersByTimeAsync(250));
    expect(client.listTweaks).toHaveBeenCalledTimes(2);
    expect(client.startTweakStream).toHaveBeenCalledExactlyOnceWith(selection.server);
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => vi.advanceTimersByTimeAsync(10_000));
    expect(client.startTweakStream).toHaveBeenCalledTimes(1);
  });

  it("retries a failed stream start while preserving loaded tweaks", async () => {
    vi.mocked(client.startTweakStream).mockRejectedValueOnce(connectionError);
    await render();
    expect(container.textContent).toContain("Demo title");
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => vi.advanceTimersByTimeAsync(250));
    expect(client.startTweakStream).toHaveBeenCalledTimes(2);
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    await act(async () => receive({ streamId: "stream-1", server: selection.server, tweaks: [] }));
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears an update error only after accepting a fresh stream snapshot", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue(modifiedResponse);
    vi.mocked(client.updateTweaks).mockRejectedValueOnce(new Error("Update failed"));
    await render();
    await act(async () => reset());
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Update failed");
    await act(async () => receive({ streamId: "other-stream", server: selection.server, tweaks: [] }));
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Update failed");
    await act(async () => receive({ streamId: "stream-1", server: selection.server, tweaks: [] }));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears an action error when the inspector reconnects", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue({ tweaks: [{ name: "Refresh preview", type: "action" }] });
    vi.mocked(client.invokeTweakAction).mockRejectedValueOnce(new Error("Action failed"));
    await render();
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Run Refresh preview"]')!.click());
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Action failed");
    await render(selection, false);
    vi.mocked(client.listTweaks).mockResolvedValue({ tweaks: [] });
    await render();
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears a rejected-update error after its reload succeeds", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue(modifiedResponse);
    vi.mocked(client.updateTweaks).mockResolvedValueOnce({
      tweaks: [],
      errors: [{ name: "Demo title", error: "Rejected" }]
    });
    await render();
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await act(async () => reset());
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Demo title: Rejected");
    await act(async () => finish({ tweaks: [] }));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("keeps loaded values visible and blocks edits and native reset while offline", async () => {
    await render();
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    expect(input.value).toBe("Recovered");
    await render(selection, false);
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector("fieldset")?.hasAttribute("inert")).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(client.stopTweakStream).toHaveBeenCalledWith("stream-1");
    await act(async () => reset());
    expect(client.updateTweaks).not.toHaveBeenCalled();
    expect(client.nativeTweaksStateChanged).toHaveBeenLastCalledWith({
      server: selection.server,
      hasResettableTweaks: false
    });
    const loads = vi.mocked(client.listTweaks).mock.calls.length;
    await act(async () => vi.advanceTimersByTimeAsync(10_000));
    expect(client.listTweaks).toHaveBeenCalledTimes(loads);
    await render();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("keeps the old values disabled until the replacement process has loaded", async () => {
    await render();
    await render(selection, false);
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    const replacement = {
      ...selection,
      appId: "phone:pid:20",
      server: { ...selection.server, socketName: "snapo_tweaks_20" }
    };
    await render(replacement);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();
    await act(async () =>
      finish({ tweaks: [{ ...response.tweaks[0], value: "New process" } as TweakList["tweaks"][number]] })
    );
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("New process");
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("backs off repeated failures and cancels retries when leaving the inspector", async () => {
    vi.mocked(client.listTweaks).mockRejectedValue(connectionError);
    await render();
    for (const delay of [250, 500, 1_000, 2_000, 4_000, 4_000]) {
      const count = vi.mocked(client.listTweaks).mock.calls.length;
      await act(async () => vi.advanceTimersByTimeAsync(delay - 1));
      expect(client.listTweaks).toHaveBeenCalledTimes(count);
      await act(async () => vi.advanceTimersByTimeAsync(1));
      expect(client.listTweaks).toHaveBeenCalledTimes(count + 1);
    }
    await act(async () => root.render(null));
    const count = vi.mocked(client.listTweaks).mock.calls.length;
    await act(async () => vi.advanceTimersByTimeAsync(20_000));
    expect(client.listTweaks).toHaveBeenCalledTimes(count);
  });

  it("stops a late stream from an inspector that is no longer selected", async () => {
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    const other = {
      ...selection,
      appId: "phone:pid:20",
      server: { ...selection.server, socketName: "snapo_tweaks_20" }
    };
    await render(other);
    await act(async () => finish({ streamId: "old-stream" }));
    expect(client.stopTweakStream).toHaveBeenCalledWith("old-stream");
    expect(client.startTweakStream).toHaveBeenLastCalledWith(other.server);
  });

  it("ignores a late old-stream event while reconnecting the same endpoint", async () => {
    await render();
    await render(selection, false);
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => receive({ streamId: "stream-1", server: selection.server, tweaks: modifiedResponse.tweaks }));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => finish(response));
  });

  it("preserves an initial snapshot that arrives before stream startup resolves", async () => {
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    await act(async () =>
      receive({ streamId: "new-stream", server: selection.server, tweaks: modifiedResponse.tweaks })
    );
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => finish({ streamId: "new-stream" }));
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Changed");
  });

  it("ignores an old stream while the new stream start is pending", async () => {
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    await act(async () =>
      receive({ streamId: "old-stream", server: selection.server, tweaks: modifiedResponse.tweaks })
    );
    await act(async () => finish({ streamId: "new-stream" }));
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
  });

  it("ignores early events when stream startup fails", async () => {
    let reject!: (cause: Error) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((_, fail) => {
          reject = fail;
        })
    );
    await render();
    await act(async () =>
      receive({ streamId: "new-stream", server: selection.server, tweaks: modifiedResponse.tweaks })
    );
    await act(async () => reject(connectionError));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => vi.advanceTimersByTimeAsync(250));
    expect(client.startTweakStream).toHaveBeenCalledTimes(2);
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
  });

  it("discards early events and stops a late stream exactly once after unmount", async () => {
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    await act(async () =>
      receive({ streamId: "new-stream", server: selection.server, tweaks: modifiedResponse.tweaks })
    );
    await act(async () => root.render(null));
    await act(async () => finish({ streamId: "new-stream" }));
    expect(client.stopTweakStream).toHaveBeenCalledExactlyOnceWith("new-stream");
    expect(container.textContent).toBe("");
  });
});
