// @vitest-environment jsdom
import { createElement, render, type JSX, type VNode } from "preact";
import { act } from "preact/test-utils";
import { renderToStaticMarkup } from "preact-render-to-string";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TweakActionDescriptor, TweakDescriptor, TweakValueDescriptor } from "../../types";
import { host } from "@snap-o/tool-host";
import { createTweaksClient, type TweaksClient } from "./client";
import {
  applyTweakUpdates,
  canResetTweaks,
  groupTweaks,
  nativePanelTweakColor,
  parseTweakColor,
  reconcileStreamedTweaks,
  TweakActionControl,
  TweakColorField,
  TweakEnumListbox,
  TweakField,
  TweaksEmptyState,
  TweaksToolApp,
  tweakColorWithPreservedAlpha
} from "./TweaksToolApp";

describe("empty tweaks tool", () => {
  const client = { openExternal: async () => {} } as unknown as TweaksClient;

  it("waits for the initial tweak request before showing an empty state", () => {
    const markup = renderToStaticMarkup(createElement(TweaksToolApp, { client, isConnected: true }));

    expect(markup).not.toContain('class="empty-detail"');
    expect(markup).not.toContain("No tweaks on screen");
  });

  it("uses the network tool empty-state layout and offers the developer guide", () => {
    const markup = renderToStaticMarkup(createElement(TweaksEmptyState, { onOpenDocs() {} }));

    expect(markup).toContain('class="empty-detail"');
    expect(markup).toContain("No tweaks on screen");
    expect(markup).toContain("Add a tweak to your app’s Compose UI to see it here.");
    expect(markup).toContain('class="text-button"');
    expect(markup).toContain("Read the developer guide");
    expect(markup).not.toContain('class="tweaks-columns"');
  });
});

describe("editable tweak colors", () => {
  it("normalizes complete RGB colors", () => {
    expect(parseTweakColor("#a1b2c3")).toBe("#A1B2C3");
  });

  it("normalizes complete RGBA colors", () => {
    expect(parseTweakColor("#a1b2c380")).toBe("#A1B2C380");
  });

  it("does not commit an incomplete color while it is being edited", () => {
    expect(parseTweakColor("#A1B2")).toBeNull();
    expect(parseTweakColor("#A1B2C3F")).toBeNull();
    expect(parseTweakColor("")).toBeNull();
  });

  it("rejects invalid hexadecimal digits", () => {
    expect(parseTweakColor("#A1B2G3")).toBeNull();
  });

  it("preserves the alpha channel when the browser color input changes RGB", () => {
    expect(tweakColorWithPreservedAlpha("#11223380", "#a1b2c3")).toBe("#A1B2C380");
  });

  it("does not add an alpha channel to RGB colors", () => {
    expect(tweakColorWithPreservedAlpha("#112233", "#a1b2c3")).toBe("#A1B2C3");
  });

  it("applies native RGBA updates", () => {
    expect(nativePanelTweakColor("#a1b2c344")).toBe("#A1B2C344");
  });

  it("keeps panel-originated changes on the current session", () => {
    expect(nativePanelTweakColor("#11223380")).toBe("#11223380");
    expect(nativePanelTweakColor("#44556640")).toBe("#44556640");
  });

  it("keeps the alpha component when a native color is translucent", () => {
    expect(nativePanelTweakColor("#a1b2c380")).toBe("#A1B2C380");
  });

  it("omits the alpha component when a native color is fully opaque", () => {
    expect(nativePanelTweakColor("#a1b2c3ff")).toBe("#A1B2C3");
  });

  it("canonicalizes originally RGBA colors to RGB when made opaque", () => {
    expect(nativePanelTweakColor("#5468FFFF")).toBe("#5468FF");
  });

  it("ignores native color updates without an alpha component", () => {
    expect(nativePanelTweakColor("#a1b2c3")).toBeNull();
  });

  it("keeps the browser-native color input when no native panel is available", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakColorField, {
        tweak: colorTweak(),
        onChange() {}
      })
    );

    expect(markup).toContain('type="color"');
    expect(markup).not.toContain("tweaks-color-button");
  });

  it("updates browser color edits before commit while preserving alpha", () => {
    const container = document.createElement("div");
    const tweak = colorTweak();
    const onChange = vi.fn();
    document.body.append(container);
    try {
      act(() => render(createElement(TweakColorField, { tweak, onChange }), container));
      const input = container.querySelector<HTMLInputElement>('input[type="color"]')!;
      for (const color of ["#112233", "#445566"]) {
        act(() => {
          input.value = color;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        });
      }
      expect(onChange.mock.calls).toEqual([
        [tweak, "#11223380"],
        [tweak, "#44556680"]
      ]);
    } finally {
      act(() => render(null, container));
      container.remove();
    }
  });

  it("renders an accessible native-panel swatch instead of the HTML color input", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakColorField, {
        tweak: colorTweak(),
        onChange() {},
        onOpenColorPanel() {}
      })
    );

    expect(markup).toContain('class="tweaks-color tweaks-color-button"');
    expect(markup).toContain('aria-label="Colors/Accent color"');
    expect(markup).toContain("background-color:#5468FF80");
    expect(markup).not.toContain('type="color"');
  });
});

describe("enumerated tweak values", () => {
  it("shows the current enum name in an accessible listbox trigger", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakField, {
        tweak: enumTweak(),
        onChange() {}
      })
    );

    expect(markup).toContain('aria-label="Appearance/Theme: System"');
    expect(markup).toContain('aria-haspopup="listbox"');
    expect(markup).toContain('aria-expanded="false"');
    expect(markup).toContain("<span>System</span>");
  });

  it("shows exact enum names and identifies the selected listbox option", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakEnumListbox, {
        id: "appearance-theme-options",
        tweak: enumTweak(),
        onChange() {},
        onClose() {}
      })
    );

    expect(markup).toContain('role="listbox"');
    expect(markup).toContain('role="option" aria-selected="true" data-option-index="0"');
    expect(markup).toContain('role="option" aria-selected="false" data-option-index="1"');
    expect(markup).toContain(">System</button>");
    expect(markup).toContain(">Dark</button>");
  });

  it("sends a primary-pointer selection before dismissing the listbox", () => {
    const events: string[] = [];
    const preventDefault = vi.fn();
    const option = enumListboxOption(1, {
      onChange: (_tweak, value) => events.push(`change:${value}`),
      onClose: () => events.push("close")
    });

    option.props.onPointerDown({ button: 0, preventDefault } as unknown as JSX.TargetedPointerEvent<HTMLButtonElement>);
    option.props.onClick({ detail: 1 } as JSX.TargetedMouseEvent<HTMLButtonElement>);

    expect(preventDefault).toHaveBeenCalledOnce();
    expect(events).toEqual(["change:Dark", "close"]);
  });

  it("ignores non-primary pointer selection", () => {
    const onChange = vi.fn();
    const onClose = vi.fn();
    const preventDefault = vi.fn();
    const option = enumListboxOption(1, { onChange, onClose });

    option.props.onPointerDown({ button: 2, preventDefault } as unknown as JSX.TargetedPointerEvent<HTMLButtonElement>);

    expect(preventDefault).not.toHaveBeenCalled();
    expect(onChange).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it("commits changed keyboard or assistive-technology selections once", () => {
    const onChange = vi.fn();
    const onClose = vi.fn();
    const current = enumListboxOption(0, { onChange, onClose });
    const changed = enumListboxOption(1, { onChange, onClose });

    current.props.onClick({ detail: 0 } as JSX.TargetedMouseEvent<HTMLButtonElement>);
    expect(onChange).not.toHaveBeenCalled();

    changed.props.onClick({ detail: 0 } as JSX.TargetedMouseEvent<HTMLButtonElement>);

    expect(onChange).toHaveBeenCalledExactlyOnceWith(enumTweak(), "Dark");
    expect(onClose).toHaveBeenCalledTimes(2);
  });

  it("updates the displayed selection when its enum name changes", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakField, {
        tweak: { ...enumTweak(), value: "Dark" },
        onChange() {}
      })
    );

    expect(markup).toContain("<span>Dark</span>");
    expect(markup).not.toContain("<span>System</span>");
  });

  it("recognizes changed and reset enum values", () => {
    expect(canResetTweaks([enumTweak()])).toBe(false);
    expect(canResetTweaks([{ ...enumTweak(), value: "Dark", modified: true }])).toBe(true);
  });

  it("preserves updated enum options while a local selection is pending", () => {
    const current = [{ ...enumTweak(), value: "Dark", modified: true }];
    const incoming = [
      {
        ...enumTweak(),
        options: ["System", "Light", "Dark"]
      }
    ];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Appearance/Theme", "Dark"]]), new Set())).toEqual([
      { ...incoming[0], value: "Dark", modified: true }
    ]);
  });
});

describe("native reset toolbar state", () => {
  it("disables reset when no tweaks exist", () => {
    expect(canResetTweaks([])).toBe(false);
  });

  it("disables reset when no tweaks are modified", () => {
    expect(canResetTweaks([tweak("Typography/Font size"), tweak("Motion/Duration")])).toBe(false);
  });

  it("enables reset when a tweak is marked modified", () => {
    expect(canResetTweaks([{ ...tweak("Typography/Font size"), value: 2, modified: true }])).toBe(true);
  });

  it("uses explicit modification status when the value equals its default", () => {
    const fontSize = tweak("Typography/Font size");

    expect(canResetTweaks([{ ...fontSize, modified: true }])).toBe(true);
    expect(canResetTweaks([{ ...fontSize, value: 2, modified: false }])).toBe(false);
    expect(canResetTweaks([fontSize])).toBe(false);
  });

  it("does not treat an action without a value or default as resettable", () => {
    expect(canResetTweaks([action("Motion/Toggle animation")])).toBe(false);
  });

  it("keeps changed value tweaks resettable when actions are present", () => {
    expect(
      canResetTweaks([action("Motion/Toggle animation"), { ...tweak("Motion/Duration"), value: 2, modified: true }])
    ).toBe(true);
  });

  it("treats an omitted modification flag as false even when the value changed", () => {
    const upstreamSetting: TweakDescriptor = {
      name: "Settings/Show hints",
      type: "boolean",
      default: false,
      value: true
    };

    expect(canResetTweaks([upstreamSetting])).toBe(false);
  });
});

describe("registered tweak actions", () => {
  it("renders an action label with an accessible Run button on the right", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakActionControl, { action: action("Motion/Toggle animation"), onInvoke() {} })
    );

    expect(markup).toContain('class="tweaks-control-label">Toggle animation</span>');
    expect(markup).toContain('class="tweaks-control-field"');
    expect(markup).toContain('class="tweaks-action-button"');
    expect(markup).toContain('aria-label="Run Motion/Toggle animation"');
    expect(markup).toContain(">Run</button>");
    expect(markup).not.toContain("tweaks-reset");
    expect(markup).not.toContain("disabled");
  });

  it("passes the selected descriptor to the action invocation handler", () => {
    const descriptor = action("Motion/Toggle animation");
    const onInvoke = vi.fn();
    const control = TweakActionControl({ action: descriptor, onInvoke });
    const [, field] = control.props.children[0].props.children;
    const button = field.props.children;

    button.props.onClick();

    expect(onInvoke).toHaveBeenCalledOnce();
    expect(onInvoke).toHaveBeenCalledWith(descriptor);
  });

  it("disables conflicted registrations and explains why they cannot run", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakActionControl, {
        action: action("Motion/Toggle animation", true),
        onInvoke() {}
      })
    );

    expect(document.createRange().createContextualFragment(markup).querySelector("button:disabled")).not.toBeNull();
    expect(markup).toContain('aria-label="Conflict Motion/Toggle animation"');
    expect(markup).toContain(">Conflict</button>");
    expect(markup).toContain('role="alert"');
    expect(markup).toContain("Conflicting registrations. Use a unique action name.");
  });

  it("disables an action while its invocation is in flight", () => {
    const markup = renderToStaticMarkup(
      createElement(TweakActionControl, {
        action: action("Motion/Toggle animation"),
        invoking: true,
        onInvoke() {}
      })
    );

    expect(document.createRange().createContextualFragment(markup).querySelector("button:disabled")).not.toBeNull();
  });

  it("invokes actions through the forwarded HTTP endpoint", async () => {
    vi.spyOn(host, "connected", "get").mockReturnValue(true);
    vi.spyOn(host, "baseURL", "get").mockReturnValue("http://127.0.0.1:1234/");
    vi.spyOn(host, "addEventListener").mockImplementation(() => {});
    const fetchRequest = vi.fn(async () => Response.json({ name: "Motion/Toggle animation" }));
    vi.stubGlobal("fetch", fetchRequest);
    const client = createTweaksClient();
    try {
      await client.invokeTweakAction({ name: "Motion/Toggle animation" });
      expect(fetchRequest).toHaveBeenCalledWith(
        new URL("http://127.0.0.1:1234/tweaks/action"),
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ name: "Motion/Toggle animation" })
        })
      );
    } finally {
      client.dispose();
      vi.restoreAllMocks();
      vi.unstubAllGlobals();
    }
  });
});

describe("streamed tweak snapshots", () => {
  it("treats an omitted modification flag in mutation responses as false", () => {
    const current: TweakDescriptor = {
      name: "Settings/Show hints",
      type: "boolean",
      default: false,
      value: true,
      modified: true
    };

    expect(applyTweakUpdates([current], [{ name: current.name, value: true }], new Map())).toEqual([
      { ...current, modified: false }
    ]);
  });

  it("restores rejected optimistic values without discarding successful batch updates", () => {
    const current = [
      { ...tweak("Motion/Duration"), value: 550, modified: true },
      { ...tweak("Typography/Font size"), value: 32, modified: true }
    ];
    const authoritative = [
      { ...tweak("Motion/Duration"), value: 550, modified: true },
      { ...tweak("Typography/Font size"), value: 1 }
    ];

    expect(reconcileStreamedTweaks(current, authoritative, new Map(), new Set())).toEqual(authoritative);
  });

  it("adds and removes a section in one update", () => {
    const current = [tweak("Typography/Font size"), tweak("Motion/Duration")];
    const incoming = [tweak("Typography/Font size"), tweak("Colors/Accent")];

    expect(reconcileStreamedTweaks(current, incoming, new Map(), new Set())).toEqual(incoming);
  });

  it("applies values changed by the Android app", () => {
    const current = [{ ...tweak("Motion/Duration"), value: 400 }];
    const incoming = [{ ...tweak("Motion/Duration"), value: 550 }];

    expect(reconcileStreamedTweaks(current, incoming, new Map(), new Set())).toEqual(incoming);
  });

  it("preserves a locally queued slider value", () => {
    const current = [{ ...tweak("Motion/Duration"), value: 700 }];
    const incoming = [{ ...tweak("Motion/Duration"), value: 550 }];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Motion/Duration", 700]]), new Set())).toEqual(current);
  });

  it("preserves a slider value while its request is in flight", () => {
    const current = [{ ...tweak("Motion/Duration"), value: 700 }];
    const incoming = [{ ...tweak("Motion/Duration"), value: 550 }];

    expect(reconcileStreamedTweaks(current, incoming, new Map(), new Set(["Motion/Duration"]))).toEqual(current);
  });

  it("preserves new descriptor metadata while keeping a pending local value", () => {
    const current = [{ ...tweak("Motion/Duration"), value: 700, modified: true }];
    const incoming: TweakDescriptor[] = [{ ...tweak("Motion/Duration"), value: 550, max: 1500 }];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Motion/Duration", 700]]), new Set())).toEqual([
      { ...incoming[0], value: 700, modified: true }
    ]);
  });

  it("adds and removes registered actions without assigning them a value", () => {
    const current = [tweak("Motion/Duration")];
    const incoming = [tweak("Motion/Duration"), action("Motion/Toggle animation")];

    expect(reconcileStreamedTweaks(current, incoming, new Map(), new Set())).toEqual(incoming);
    expect(reconcileStreamedTweaks(incoming, current, new Map(), new Set())).toEqual(current);
  });

  it("preserves action descriptors when a value update has the same name queued", () => {
    const current = [action("Motion/Toggle animation")];
    const incoming = [action("Motion/Toggle animation", true)];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Motion/Toggle animation", 1]]), new Set())).toEqual(
      incoming
    );
  });

  it("preserves a pending reset until its authoritative response arrives", () => {
    const current = [{ ...tweak("Motion/Duration"), value: 700, modified: true }];
    const incoming = [{ ...tweak("Motion/Duration"), value: 550, modified: false }];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Motion/Duration", null]]), new Set())).toEqual(
      current
    );
    expect(canResetTweaks(current)).toBe(true);
    expect(applyTweakUpdates(current, [{ name: "Motion/Duration", value: 550 }], new Map())).toEqual(incoming);
  });

  it("accepts owner modification status from a streamed update", () => {
    const current = [{ ...tweak("Motion/Duration"), modified: false }];
    const incoming = [{ ...tweak("Motion/Duration"), modified: true }];

    expect(reconcileStreamedTweaks(current, incoming, new Map(), new Set())).toEqual(incoming);
  });
});

describe("stable tweak section columns", () => {
  it("assigns sections alternately as they first appear", () => {
    const ordering = { sections: new Map<string, number>(), tweaks: new Map<string, number>() };
    const columns = groupTweaks(
      [tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")],
      ordering
    );

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([
      ["Colors", "Typography"],
      ["Motion"]
    ]);
  });

  it("keeps sections in their original columns when another section disappears", () => {
    const ordering = { sections: new Map<string, number>(), tweaks: new Map<string, number>() };

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")], ordering);

    const columns = groupTweaks([tweak("Typography/Font size"), tweak("Colors/Text")], ordering);

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Colors", "Typography"], []]);
  });

  it("restores a returning section to its original column", () => {
    const ordering = { sections: new Map<string, number>(), tweaks: new Map<string, number>() };

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")], ordering);
    groupTweaks([tweak("Colors/Text"), tweak("Typography/Font size")], ordering);

    const columns = groupTweaks(
      [tweak("Motion/Duration"), tweak("Typography/Font size"), tweak("Colors/Text")],
      ordering
    );

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([
      ["Colors", "Typography"],
      ["Motion"]
    ]);
  });

  it("keeps section order independent between tool pages", () => {
    const ordering = { sections: new Map<string, number>(), tweaks: new Map<string, number>() };

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration")], ordering);

    const columns = groupTweaks([tweak("Motion/Duration"), tweak("Colors/Text")], {
      sections: new Map(),
      tweaks: new Map()
    });

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Motion"], ["Colors"]]);
  });

  it("keeps registered actions in the same named sections as value tweaks", () => {
    const columns = groupTweaks([tweak("Motion/Duration"), action("Motion/Toggle animation")], {
      sections: new Map(),
      tweaks: new Map()
    });

    expect(columns[0][0].tweaks.map((descriptor) => descriptor.name)).toEqual([
      "Motion/Duration",
      "Motion/Toggle animation"
    ]);
  });
});

function tweak(name: string): TweakValueDescriptor {
  return {
    name,
    type: "int",
    default: 1,
    value: 1,
    modified: false
  };
}

function colorTweak(): TweakValueDescriptor {
  return {
    name: "Colors/Accent",
    type: "color",
    default: "#5468FF80",
    value: "#5468FF80",
    modified: false
  };
}

function enumTweak(): TweakValueDescriptor {
  return {
    name: "Appearance/Theme",
    type: "enum",
    default: "System",
    value: "System",
    modified: false,
    options: ["System", "Dark"]
  };
}

function enumListboxOption(
  index: number,
  handlers: {
    onChange(tweak: TweakValueDescriptor, value: TweakValueDescriptor["value"]): void;
    onClose(): void;
  }
): VNode<{
  onPointerDown(event: JSX.TargetedPointerEvent<HTMLButtonElement>): void;
  onClick(event: JSX.TargetedMouseEvent<HTMLButtonElement>): void;
}> {
  const listbox = TweakEnumListbox({
    id: "appearance-theme-options",
    tweak: enumTweak(),
    ...handlers
  });
  return listbox.props.children[index];
}

function action(name: string, conflicted = false): TweakActionDescriptor {
  return {
    name,
    type: "action",
    ...(conflicted ? { conflicted: true } : {})
  };
}

describe("Tweaks event stream transport", () => {
  let client: TweaksClient;
  let streams: FakeEventSource[];
  class FakeEventSource extends EventTarget {
    close = vi.fn();
    constructor(readonly url: URL) {
      super();
      streams.push(this);
    }
  }

  beforeEach(() => {
    streams = [];
    vi.useFakeTimers();
    vi.spyOn(host, "connected", "get").mockReturnValue(true);
    vi.spyOn(host, "baseURL", "get").mockReturnValue("http://127.0.0.1:1234/");
    vi.stubGlobal("EventSource", FakeEventSource);
    client = createTweaksClient();
  });

  afterEach(() => {
    client.dispose();
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("waits for open before resolving and delivers snapshots until stopped", async () => {
    const changed = vi.fn();
    client.onTweaksChanged(changed);
    const started = client.startTweakStream();
    const ready = vi.fn();
    void started.then(ready);
    await Promise.resolve();
    expect(ready).not.toHaveBeenCalled();
    expect(streams[0].url.href).toBe("http://127.0.0.1:1234/tweaks/events");
    streams[0].dispatchEvent(new Event("open"));
    const { streamId } = await started;
    streams[0].dispatchEvent(new MessageEvent("tweaks", { data: '{"tweaks":[]}' }));
    expect(changed).toHaveBeenCalledExactlyOnceWith({ streamId, tweaks: [] });
    await client.stopTweakStream(streamId);
    streams[0].dispatchEvent(new MessageEvent("tweaks", { data: '{"tweaks":[]}' }));
    expect(changed).toHaveBeenCalledOnce();
    expect(streams[0].close).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("rejects an initial error instead of letting EventSource retry indefinitely", async () => {
    const failed = vi.fn();
    const started = client.startTweakStream(failed);
    const rejected = expect(started).rejects.toThrow("Tweaks event stream disconnected.");
    streams[0].dispatchEvent(new Event("error"));
    streams[0].dispatchEvent(new Event("open"));
    await rejected;
    expect(failed).not.toHaveBeenCalled();
    expect(streams[0].close).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it.each(["timeout", "dispose", "host change"])("settles pending startup after %s", async (reason) => {
    const started = client.startTweakStream();
    const rejected = expect(started).rejects.toThrow(reason === "timeout" ? "timed out" : "disconnected");
    if (reason === "timeout") await vi.advanceTimersByTimeAsync(5_000);
    else if (reason === "dispose") client.dispose();
    else host.dispatchEvent(new Event("connection"));
    await rejected;
    expect(streams[0].close).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("reports a live stream failure once and drops subsequent snapshots", async () => {
    const failed = vi.fn();
    const changed = vi.fn();
    client.onTweaksChanged(changed);
    const started = client.startTweakStream(failed);
    streams[0].dispatchEvent(new Event("open"));
    const { streamId } = await started;
    streams[0].dispatchEvent(new Event("error"));
    streams[0].dispatchEvent(new Event("error"));
    streams[0].dispatchEvent(new MessageEvent("tweaks", { data: '{"tweaks":[]}' }));
    await client.stopTweakStream(streamId);
    expect(failed).toHaveBeenCalledExactlyOnceWith(expect.any(Error));
    expect(streams[0].close).toHaveBeenCalledOnce();
    expect(changed).not.toHaveBeenCalled();
  });
});
