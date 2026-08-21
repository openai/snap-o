import { createElement, type MouseEvent, type PointerEvent, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type {
  SelectedAppInspector,
  TweakActionDescriptor,
  TweakDescriptor,
  TweakValueDescriptor
} from "../../network/bridge-types";
import { createNetworkClient, type NetworkClient } from "../../network/client";
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
  TweaksInspectorApp,
  tweakColorWithPreservedAlpha,
  tweakResetValue
} from "./TweaksInspectorApp";

describe("empty tweaks inspector", () => {
  const client = { usesNativeServerPicker: true, openExternal: async () => {} } as unknown as NetworkClient;
  const selection: SelectedAppInspector = {
    appId: "pixel:com.example.settings",
    kind: "tweaks",
    server: { deviceId: "pixel", socketName: "snapo_tweaks_10" }
  };

  it("waits for the initial tweak request before showing an empty state", () => {
    const markup = renderToStaticMarkup(
      createElement(TweaksInspectorApp, { client, apps: [], selection, onSelect() {} })
    );

    expect(markup).not.toContain('class="empty-detail"');
    expect(markup).not.toContain("No tweaks on screen");
  });

  it("uses the network inspector empty-state layout and offers the developer guide", () => {
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
    expect(nativePanelTweakColor({ color: "#a1b2c344", sessionId: "active" }, "active")).toBe("#A1B2C344");
  });

  it("ignores stale native color events from a previously opened field", () => {
    expect(nativePanelTweakColor({ color: "#a1b2c344", sessionId: "previous" }, "active")).toBeNull();
  });

  it("keeps panel-originated changes on the current session", () => {
    expect(nativePanelTweakColor({ color: "#11223380", sessionId: "current" }, "current")).toBe("#11223380");
    expect(nativePanelTweakColor({ color: "#44556640", sessionId: "current" }, "current")).toBe("#44556640");
  });

  it("rejects queued panel events after an external change refreshes its session", () => {
    expect(nativePanelTweakColor({ color: "#11223380", sessionId: "before-sync" }, "after-sync")).toBeNull();
    expect(nativePanelTweakColor({ color: "#44556640", sessionId: "after-sync" }, "after-sync")).toBe("#44556640");
  });

  it("closes only the native color-panel session that lost its tweak", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("window", { webkit: { messageHandlers: { snapoNetwork: { postMessage } } } });

    try {
      const client = createNetworkClient();
      await client.closeNativeColorPanel?.("removed-session");

      expect(postMessage).toHaveBeenCalledWith({
        command: "closeNativeColorPanel",
        payload: { sessionId: "removed-session" }
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("keeps the alpha component when a native color is translucent", () => {
    expect(nativePanelTweakColor({ color: "#a1b2c380", sessionId: "active" }, "active")).toBe("#A1B2C380");
  });

  it("omits the alpha component when a native color is fully opaque", () => {
    expect(nativePanelTweakColor({ color: "#a1b2c3ff", sessionId: "active" }, "active")).toBe("#A1B2C3");
  });

  it("canonicalizes originally RGBA colors to RGB when made opaque", () => {
    expect(nativePanelTweakColor({ color: "#5468FFFF", sessionId: "active" }, "active")).toBe("#5468FF");
  });

  it("ignores native color updates without an alpha component", () => {
    expect(nativePanelTweakColor({ color: "#a1b2c3", sessionId: "active" }, "active")).toBeNull();
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

    option.props.onPointerDown({ button: 0, preventDefault } as unknown as PointerEvent<HTMLButtonElement>);
    option.props.onClick({ detail: 1 } as MouseEvent<HTMLButtonElement>);

    expect(preventDefault).toHaveBeenCalledOnce();
    expect(events).toEqual(["change:Dark", "close"]);
  });

  it("ignores non-primary pointer selection", () => {
    const onChange = vi.fn();
    const onClose = vi.fn();
    const preventDefault = vi.fn();
    const option = enumListboxOption(1, { onChange, onClose });

    option.props.onPointerDown({ button: 2, preventDefault } as unknown as PointerEvent<HTMLButtonElement>);

    expect(preventDefault).not.toHaveBeenCalled();
    expect(onChange).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it("commits changed keyboard or assistive-technology selections once", () => {
    const onChange = vi.fn();
    const onClose = vi.fn();
    const current = enumListboxOption(0, { onChange, onClose });
    const changed = enumListboxOption(1, { onChange, onClose });

    current.props.onClick({ detail: 0 } as MouseEvent<HTMLButtonElement>);
    expect(onChange).not.toHaveBeenCalled();

    changed.props.onClick({ detail: 0 } as MouseEvent<HTMLButtonElement>);

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

  it("infers modification status from legacy tweak values", () => {
    const fontSize = tweak("Typography/Font size");

    expect(canResetTweaks([{ ...fontSize, value: 2 }], 2)).toBe(true);
    expect(canResetTweaks([{ ...fontSize, modified: true }], 2)).toBe(false);
  });

  it("resets legacy tweaks by restoring their descriptor defaults", () => {
    const fontSize = { ...tweak("Typography/Font size"), value: 2 };

    expect(tweakResetValue(fontSize, undefined)).toBe(fontSize.default);
    expect(tweakResetValue(fontSize, 1)).toBe(fontSize.default);
    expect(tweakResetValue(fontSize, 2)).toBe(fontSize.default);
    expect(tweakResetValue(fontSize, 3)).toBe(fontSize.default);
  });

  it("resets current tweaks using the owner-aware null operation", () => {
    expect(tweakResetValue(tweak("Typography/Font size"), 4)).toBeNull();
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

    expect(canResetTweaks([upstreamSetting], 4)).toBe(false);
    expect(canResetTweaks([upstreamSetting], 3)).toBe(true);
    expect(canResetTweaks([upstreamSetting], 2)).toBe(true);
  });
});

describe("registered tweak actions", () => {
  const server = { deviceId: "pixel", socketName: "snapo_tweaks_10" };

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

    expect(markup).toContain('disabled=""');
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

    expect(markup).toContain('disabled=""');
  });

  it("invokes actions through the native desktop bridge", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("window", { webkit: { messageHandlers: { snapoNetwork: { postMessage } } } });

    try {
      await createNetworkClient().invokeTweakAction({ server, name: "Motion/Toggle animation" });

      expect(postMessage).toHaveBeenCalledWith({
        command: "invokeTweakAction",
        payload: { server, name: "Motion/Toggle animation" }
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("posts named action invocations through the browser inspector proxy", async () => {
    const fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ name: "Motion/Toggle animation" })
    });
    vi.stubGlobal("window", {});
    vi.stubGlobal("fetch", fetch);

    try {
      await createNetworkClient().invokeTweakAction({ server, name: "Motion/Toggle animation" });

      expect(fetch).toHaveBeenCalledWith("/api/inspector/tweaks/action", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ server, name: "Motion/Toggle animation" })
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("preserves upstream conflict errors instead of replacing them with an HTTP status", async () => {
    vi.stubGlobal("window", {});
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        status: 409,
        json: async () => ({ error: "Action Motion/Toggle animation has conflicting registrations." })
      })
    );

    try {
      await expect(
        createNetworkClient().invokeTweakAction({ server, name: "Motion/Toggle animation" })
      ).rejects.toThrow("Action Motion/Toggle animation has conflicting registrations.");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("preserves generic HTTP status errors for unrelated network requests", async () => {
    const json = vi.fn().mockResolvedValue({ error: "Unrelated conflict" });
    vi.stubGlobal("window", {});
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 409, json }));

    try {
      await expect(createNetworkClient().listServers()).rejects.toThrow("Request failed with 409");
      expect(json).not.toHaveBeenCalled();
    } finally {
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

  it("infers legacy modification status from an authoritative mutation response", () => {
    const current = { ...tweak("Motion/Duration"), value: 2, modified: true };

    expect(applyTweakUpdates([current], [{ name: current.name, value: current.default }], new Map(), 3)).toEqual([
      { ...current, value: current.default, modified: false }
    ]);
    expect(applyTweakUpdates([current], [{ name: current.name, value: 3 }], new Map(), 3)).toEqual([
      { ...current, value: 3, modified: true }
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
    const ordering = new Map();
    const columns = groupTweaks(
      [tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")],
      "pixel:settings",
      ordering
    );

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([
      ["Colors", "Typography"],
      ["Motion"]
    ]);
  });

  it("keeps sections in their original columns when another section disappears", () => {
    const ordering = new Map();
    const app = "pixel:settings";

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")], app, ordering);

    const columns = groupTweaks([tweak("Typography/Font size"), tweak("Colors/Text")], app, ordering);

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Colors", "Typography"], []]);
  });

  it("restores a returning section to its original column", () => {
    const ordering = new Map();
    const app = "pixel:settings";

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")], app, ordering);
    groupTweaks([tweak("Colors/Text"), tweak("Typography/Font size")], app, ordering);

    const columns = groupTweaks(
      [tweak("Motion/Duration"), tweak("Typography/Font size"), tweak("Colors/Text")],
      app,
      ordering
    );

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([
      ["Colors", "Typography"],
      ["Motion"]
    ]);
  });

  it("remembers section order independently for each app", () => {
    const ordering = new Map();

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration")], "pixel:settings", ordering);

    const columns = groupTweaks([tweak("Motion/Duration"), tweak("Colors/Text")], "pixel:demo", ordering);

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Motion"], ["Colors"]]);
  });

  it("keeps registered actions in the same named sections as value tweaks", () => {
    const columns = groupTweaks([tweak("Motion/Duration"), action("Motion/Toggle animation")], "pixel:demo", new Map());

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
): ReactElement<{
  onPointerDown(event: PointerEvent<HTMLButtonElement>): void;
  onClick(event: MouseEvent<HTMLButtonElement>): void;
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
