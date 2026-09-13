// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { render as renderPreact } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TweakList } from "../../types";
import type { TweaksClient } from "./client";
import { host, type ToolConnection, type ToolbarAction } from "@snap-o/tool-host";
import { TweaksToolApp } from "./TweaksToolApp";

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
  let connection: ToolConnection;
  let receive: (snapshot: TweakList) => void;
  let fail: (error: Error) => void;
  let initialSnapshot: TweakList | null;
  let stops: ReturnType<typeof vi.fn>[];
  let reset: () => void;
  let toolbar: readonly ToolbarAction[] = [];
  const setSnapshot = (snapshot: TweakList) => {
    initialSnapshot = snapshot;
  };

  beforeEach(() => {
    vi.useFakeTimers();
    initialSnapshot = response;
    stops = [];
    connection = {
      baseURL: "http://127.0.0.1:1234/",
      processIdentity: "boot:20:123",
      signal: new AbortController().signal
    };
    vi.spyOn(host, "setToolbar").mockImplementation(async ({ actions = [] }) => {
      toolbar = actions;
      reset = () => {
        const action = actions[0];
        if (action && action.enabled !== false) action.onClick();
      };
    });
    client = {
      listTweaks: vi.fn(async () => response),
      subscribeTweaks: vi.fn((_connection, onSnapshot, onError) => {
        receive = onSnapshot;
        fail = onError;
        const stop = vi.fn();
        stops.push(stop);
        const snapshot = initialSnapshot;
        if (snapshot) queueMicrotask(() => onSnapshot(snapshot));
        return stop;
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

  async function render(connected = true) {
    await act(async () =>
      renderPreact(<TweaksToolApp client={client} connection={connected ? connection : null} />, container)
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
    setSnapshot(tweaks);
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

    await act(async () => receive({ tweaks: tweaks.tweaks }));
    expect(haloList.hidden).toBe(true);
    await act(async () => halo.click());
    expect(haloList.hidden).toBe(false);
  });

  it("places each bounded numeric slider beside its value", async () => {
    setSnapshot({
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
    setSnapshot({
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
        tweaks: [{ name: "Demo title", type: "string", value: "Streamed", default: "Default" }]
      })
    );
    expect(container.querySelector('input[type="text"]')).toBe(input);
    expect(input.value).toBe("Streamed");
    expect(document.activeElement).toBe(input);
  });

  it("clears an action error when the tool reconnects", async () => {
    setSnapshot({ tweaks: [{ name: "Refresh preview", type: "action" }] });
    vi.mocked(client.invokeTweakAction).mockRejectedValueOnce(new Error("Action failed"));
    await render();
    await act(() => container.querySelector<HTMLButtonElement>('[aria-label="Run Refresh preview"]')!.click());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Action failed");
    await render(false);
    setSnapshot({ tweaks: [] });
    await render();
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("clears a rejected-update error after its reload succeeds", async () => {
    setSnapshot(modifiedResponse);
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
    expect(stops[0]).toHaveBeenCalledOnce();
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

  it("waits for the initial SSE snapshot without fetching a separate list", async () => {
    initialSnapshot = null;
    await render();
    expect(client.listTweaks).not.toHaveBeenCalled();
    expect(toolbar[0]?.enabled).toBe(false);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(299);
    });
    expect(container.querySelector('[role="status"]')).toBeNull();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(container.querySelector('[role="status"]')?.textContent).toBe("Waiting for tool");
    await act(async () => receive(response));
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
  });

  it("does not flash a waiting indicator for a quick initial snapshot", async () => {
    initialSnapshot = null;
    await render();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(100);
      receive(response);
    });
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(300);
    });
    expect(container.querySelector('[role="status"]')).toBeNull();
  });

  it("retries a failed subscription without changing the selected tool", async () => {
    vi.mocked(client.subscribeTweaks).mockImplementationOnce(() => {
      throw connectionError;
    });
    await render();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain(connectionError.message);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
    expect(client.subscribeTweaks).toHaveBeenCalledTimes(2);
    expect(client.listTweaks).not.toHaveBeenCalled();
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
  });

  it("keeps values disabled after stream failure until the next snapshot", async () => {
    await render();
    const oldReceive = receive;
    await act(async () => fail(connectionError));
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    initialSnapshot = null;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(250);
    });
    expect(stops[0]).toHaveBeenCalledOnce();
    await act(async () => oldReceive(modifiedResponse));
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => receive(modifiedResponse));
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Changed");
  });

  it("clears an update error only after accepting a fresh snapshot", async () => {
    initialSnapshot = modifiedResponse;
    vi.mocked(client.updateTweaks).mockRejectedValueOnce(new Error("Update failed"));
    await render();
    await act(() => reset());
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("Update failed");
    await act(async () => receive({ tweaks: [] }));
    expect(container.querySelector('[role="alert"]')).toBeNull();
    expect(container.textContent).toContain("No tweaks on screen");
  });

  it("backs off repeated failures and cancels retries when leaving the tool", async () => {
    vi.mocked(client.subscribeTweaks).mockImplementation(() => {
      throw connectionError;
    });
    await render();
    for (const delay of [250, 500, 1_000, 2_000, 4_000, 4_000]) {
      const count = vi.mocked(client.subscribeTweaks).mock.calls.length;
      await act(async () => {
        await vi.advanceTimersByTimeAsync(delay - 1);
      });
      expect(client.subscribeTweaks).toHaveBeenCalledTimes(count);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1);
      });
      expect(client.subscribeTweaks).toHaveBeenCalledTimes(count + 1);
    }
    await act(async () => renderPreact(null, container));
    const count = vi.mocked(client.subscribeTweaks).mock.calls.length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(20_000);
    });
    expect(client.subscribeTweaks).toHaveBeenCalledTimes(count);
  });

  it.each([false, true])("ignores old callbacks when replacing a connection (new process: %s)", async (newProcess) => {
    await render();
    const oldReceive = receive;
    const oldFail = fail;
    initialSnapshot = null;
    connection = {
      ...connection,
      signal: new AbortController().signal,
      processIdentity: newProcess ? "boot:20:456" : connection.processIdentity
    };
    await render();
    expect(stops[0]).toHaveBeenCalledOnce();
    expect(container.querySelector("fieldset")?.disabled).toBe(true);
    await act(async () => {
      oldReceive(modifiedResponse);
      oldFail(connectionError);
    });
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Recovered");
    expect(container.querySelector('[role="alert"]')).toBeNull();
    await act(async () => receive(modifiedResponse));
    expect(container.querySelector("fieldset")?.disabled).toBe(false);
    expect(container.querySelector<HTMLInputElement>('input[type="text"]')?.value).toBe("Changed");
  });

  it("cleans up immediately while awaiting a snapshot and ignores late callbacks after unmount", async () => {
    initialSnapshot = null;
    await render();
    await act(async () => renderPreact(null, container));
    expect(stops[0]).toHaveBeenCalledOnce();
    await act(async () => {
      receive(response);
      fail(connectionError);
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(client.subscribeTweaks).toHaveBeenCalledOnce();
    expect(container.textContent).toBe("");
  });
});
