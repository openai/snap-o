// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render as renderPreact } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TweakList, TweakStreamEvent } from "../../types";
import type { TweaksClient } from "./client";
import { host, type ToolbarAction } from "@snap-o/host";
import { TweaksInspectorApp } from "./TweaksInspectorApp";

const response: TweakList = {
  tweaks: [{ name: "Demo title", type: "string", value: "Recovered", default: "Default" }]
};
const modifiedResponse: TweakList = {
  tweaks: [{ name: "Demo title", type: "string", value: "Changed", default: "Default", modified: true }]
};
const connectionError = new Error("Could not connect to the server.");

describe("Tweaks connection recovery", () => {
  let container: HTMLDivElement;
  let client: TweaksClient;
  let receive: (event: TweakStreamEvent) => void;
  let reset: () => void;
  let toolbar: readonly ToolbarAction[] = [];

  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(host, "setToolbar").mockImplementation(async ({ start: actions }) => {
      toolbar = actions;
      reset = () => {
        const action = actions[0];
        if (action?.type === "button" && action.enabled !== false) action.onClick();
      };
    });
    client = {
      listTweaks: vi.fn(async () => response),
      startTweakStream: vi.fn(async () => ({ streamId: "stream-1" })),
      stopTweakStream: vi.fn(async () => {}),
      onTweaksChanged: vi.fn((callback) => {
        receive = callback;
        return () => {};
      }),
      updateTweaks: vi.fn(async () => ({ tweaks: [] })),
      invokeTweakAction: vi.fn(async () => {}),
      openExternal: vi.fn(async () => {}),
      dispose: vi.fn()
    };
    container = document.createElement("div");
    document.body.append(container);
  });

  afterEach(async () => {
    await act(async () => renderPreact(null, container));
    container.remove();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  async function render(isConnected = true, revision = 0) {
    await act(async () =>
      renderPreact(
        <TweaksInspectorApp client={client} connectionRevision={revision} isConnected={isConnected} />,
        container
      )
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
  }

  it("collapses one named section and keeps it collapsed after a stream update", async () => {
    const tweaks: TweakList = {
      tweaks: [
        { name: "Halo/Opacity", type: "float", value: 0.5, default: 0.5, min: 0, max: 1 },
        { name: "Motion/Speed", type: "float", value: 1, default: 1, min: 0, max: 2 }
      ]
    };
    vi.mocked(client.listTweaks).mockResolvedValue(tweaks);
    await render();

    const buttons = container.querySelectorAll<HTMLButtonElement>(".tweaks-section-toggle");
    const halo = Array.from(buttons).find((button) => button.textContent?.includes("Halo"))!;
    const motion = Array.from(buttons).find((button) => button.textContent?.includes("Motion"))!;
    const haloList = document.getElementById(halo.getAttribute("aria-controls")!)!;
    const motionList = document.getElementById(motion.getAttribute("aria-controls")!)!;
    expect(halo.getAttribute("aria-expanded")).toBe("true");
    expect(haloList.hidden).toBe(false);

    await act(async () => halo.click());
    expect(halo.getAttribute("aria-expanded")).toBe("false");
    expect(haloList.hidden).toBe(true);
    expect(motion.getAttribute("aria-expanded")).toBe("true");
    expect(motionList.hidden).toBe(false);

    await act(async () => receive({ streamId: "stream-1", tweaks: tweaks.tweaks }));
    expect(haloList.hidden).toBe(true);
    await act(async () => halo.click());
    expect(haloList.hidden).toBe(false);
  });

  it("places each bounded numeric slider beside its value", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue({
      tweaks: [
        { name: "Halo/Opacity", type: "float", value: 0.5, default: 0.5, min: 0, max: 1 },
        { name: "Halo/Iterations", type: "int", value: 3, default: 3 }
      ]
    });
    await render();

    const range = container.querySelector<HTMLInputElement>('.tweaks-control-line-range input[type="range"]')!;
    const number = range.parentElement!.querySelector<HTMLInputElement>('input[type="number"]')!;
    expect(number.value).toBe("0.5");
    expect(range.parentElement?.querySelector(".tweaks-control-label")?.textContent).toBe("Opacity");
    expect(container.querySelectorAll('.tweaks-control-line input[type="range"]')).toHaveLength(1);
  });

  it("keeps enum options open for internal focus and closes them when focus leaves", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue({
      tweaks: [{ name: "Theme", type: "enum", value: "Light", default: "Light", options: ["Light", "Dark"] }]
    });
    await render();
    const trigger = container.querySelector<HTMLButtonElement>('[aria-haspopup="listbox"]')!;
    await act(() => {
      trigger.focus();
      trigger.click();
    });
    const option = container.querySelector<HTMLButtonElement>('[role="option"]')!;
    await act(() => option.focus());
    expect(container.querySelector('[role="listbox"]')).not.toBeNull();

    const outside = document.createElement("button");
    container.append(outside);
    await act(() => outside.focus());
    expect(container.querySelector('[role="listbox"]')).toBeNull();
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(client.updateTweaks).not.toHaveBeenCalled();
  });

  it("shows status text while loading", async () => {
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
    expect(status?.querySelector("svg")).not.toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();

    await act(async () => finish(response));
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
  });

  it("sends text input before blur and preserves focus during live updates", async () => {
    vi.mocked(client.updateTweaks).mockResolvedValue({
      tweaks: [{ name: "Demo title", value: "Edited", modified: true }]
    });
    await render();
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    input.focus();
    await act(() => {
      input.value = "Edited";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(client.updateTweaks).toHaveBeenCalledExactlyOnceWith({
      values: { "Demo title": "Edited" }
    });
    expect(document.activeElement).toBe(input);

    await act(async () =>
      receive({
        streamId: "stream-1",

        tweaks: [{ name: "Demo title", type: "string", value: "Streamed", default: "Default" }]
      })
    );
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(input.value).toBe("Streamed");
    expect(document.activeElement).toBe(input);
  });

  it("retries a failed initial request without changing the selected inspector", async () => {
    vi.mocked(client.listTweaks).mockRejectedValueOnce(connectionError);
    await render();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain(connectionError.message);
    expect(client.startTweakStream).not.toHaveBeenCalled();
    expect(container.querySelector(".inspector-open-app")).toBeNull();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
    expect(client.listTweaks).toHaveBeenCalledTimes(2);
    expect(client.startTweakStream).toHaveBeenCalledExactlyOnceWith(expect.any(Function));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector(".inspector-open-app")).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(client.startTweakStream).toHaveBeenCalledTimes(1);
  });

  it("retries a failed stream start while preserving loaded tweaks", async () => {
    vi.mocked(client.startTweakStream).mockRejectedValueOnce(connectionError);
    await render();
    expect(container.textContent).toContain("Demo title");
    expect(container.querySelector('[role="alert"]')?.textContent).toBe(connectionError.message);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
    expect(client.startTweakStream).toHaveBeenCalledTimes(2);
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    await act(async () => receive({ streamId: "stream-1", tweaks: [] }));
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears an update error only after accepting a fresh stream snapshot", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue(modifiedResponse);
    vi.mocked(client.updateTweaks).mockRejectedValueOnce(new Error("Update failed"));
    await render();
    await act(() => reset());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Update failed");
    await act(async () => receive({ streamId: "other-stream", tweaks: [] }));
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Update failed");
    await act(async () => receive({ streamId: "stream-1", tweaks: [] }));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears an action error when the inspector reconnects", async () => {
    vi.mocked(client.listTweaks).mockResolvedValue({ tweaks: [{ name: "Refresh preview", type: "action" }] });
    vi.mocked(client.invokeTweakAction).mockRejectedValueOnce(new Error("Action failed"));
    await render();
    await act(() => container.querySelector<HTMLButtonElement>('[aria-label="Run Refresh preview"]')!.click());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Action failed");
    await render(false);
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
    await act(() => reset());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Demo title: Rejected");
    await act(async () => finish({ tweaks: [] }));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("keeps loaded values visible and blocks edits and native reset while offline", async () => {
    await render();
    const input = container.querySelector<HTMLInputElement>('input[type="text"]')!;
    expect(input.value).toBe("Recovered");
    await render(false);
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector("fieldset")?.hasAttribute("inert")).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(client.stopTweakStream).toHaveBeenCalledWith("stream-1");
    await act(() => reset());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(client.updateTweaks).not.toHaveBeenCalled();
    expect(toolbar[0]?.enabled).toBe(false);
    const loads = vi.mocked(client.listTweaks).mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(client.listTweaks).toHaveBeenCalledTimes(loads);
    await render();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("keeps the old values disabled until the replacement process has loaded", async () => {
    await render();
    await render(false);
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render(true, 1);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector('[role="status"]')).toBeNull();
    await act(async () =>
      finish({ tweaks: [{ ...response.tweaks[0], value: "New process" } as TweakList["tweaks"][number]] })
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("New process");
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("backs off repeated failures and cancels retries when leaving the inspector", async () => {
    vi.mocked(client.listTweaks).mockRejectedValue(connectionError);
    await render();
    for (const delay of [250, 500, 1_000, 2_000, 4_000, 4_000]) {
      const count = vi.mocked(client.listTweaks).mock.calls.length;
      await act(async () => {
        await vi.advanceTimersByTimeAsync(delay - 1);
      });
      expect(client.listTweaks).toHaveBeenCalledTimes(count);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1);
      });
      expect(client.listTweaks).toHaveBeenCalledTimes(count + 1);
    }
    await act(async () => renderPreact(null, container));
    const count = vi.mocked(client.listTweaks).mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(20_000);
    });
    expect(client.listTweaks).toHaveBeenCalledTimes(count);
  });

  it("disables stale values after a live stream failure and waits for the replacement stream", async () => {
    let fail!: (error: Error) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(async (onError) => {
      fail = onError!;
      return { streamId: "stream-1" };
    });
    await render();
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    await act(async () => fail(connectionError));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.textContent).toContain(connectionError.message);
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
    await act(async () => receive({ streamId: "stream-1", tweaks: modifiedResponse.tweaks }));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => finish({ streamId: "stream-2" }));
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    expect(client.listTweaks).toHaveBeenCalledTimes(2);
  });

  it("stops a late stream from an earlier connection", async () => {
    let finish!: (value: { streamId: string }) => void;
    vi.mocked(client.startTweakStream).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    await render(true, 1);
    await act(async () => finish({ streamId: "old-stream" }));
    expect(client.stopTweakStream).toHaveBeenCalledWith("old-stream");
    expect(client.startTweakStream).toHaveBeenCalledTimes(2);
  });

  it("ignores a late old-stream event while reconnecting the same endpoint", async () => {
    await render();
    await render(false);
    let finish!: (value: TweakList) => void;
    vi.mocked(client.listTweaks).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    await render();
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => receive({ streamId: "stream-1", tweaks: modifiedResponse.tweaks }));
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
    await act(async () => receive({ streamId: "new-stream", tweaks: modifiedResponse.tweaks }));
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
    await act(async () => receive({ streamId: "old-stream", tweaks: modifiedResponse.tweaks }));
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
    await act(async () => receive({ streamId: "new-stream", tweaks: modifiedResponse.tweaks }));
    await act(async () => reject(connectionError));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
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
    await act(async () => receive({ streamId: "new-stream", tweaks: modifiedResponse.tweaks }));
    await act(async () => renderPreact(null, container));
    await act(async () => finish({ streamId: "new-stream" }));
    expect(client.stopTweakStream).toHaveBeenCalledExactlyOnceWith("new-stream");
    expect(container.textContent).toBe("");
  });
});
