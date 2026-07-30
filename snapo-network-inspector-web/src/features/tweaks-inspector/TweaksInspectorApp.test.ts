import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { TweakDescriptor } from "../../network/bridge-types";
import {
  canResetTweaks,
  groupTweaks,
  nativePanelTweakColor,
  parseTweakColor,
  reconcileStreamedTweaks,
  TweakColorField,
  tweakColorWithPreservedAlpha
} from "./TweaksInspectorApp";

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

describe("native reset toolbar state", () => {
  it("disables reset when no tweaks exist", () => {
    expect(canResetTweaks([])).toBe(false);
  });

  it("disables reset when all tweaks are at their defaults", () => {
    expect(canResetTweaks([tweak("Typography/Font size"), tweak("Motion/Duration")])).toBe(false);
  });

  it("enables reset immediately when a tweak changes", () => {
    expect(canResetTweaks([{ ...tweak("Typography/Font size"), value: 2 }])).toBe(true);
  });

  it("disables reset when every changed tweak returns to its default", () => {
    const fontSize = tweak("Typography/Font size");

    expect(canResetTweaks([{ ...fontSize, value: 2 }])).toBe(true);
    expect(canResetTweaks([fontSize])).toBe(false);
  });
});

describe("streamed tweak snapshots", () => {
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
    const current = [{ ...tweak("Motion/Duration"), value: 700 }];
    const incoming: TweakDescriptor[] = [{ ...tweak("Motion/Duration"), value: 550, max: 1500 }];

    expect(reconcileStreamedTweaks(current, incoming, new Map([["Motion/Duration", 700]]), new Set())).toEqual([
      { ...incoming[0], value: 700 }
    ]);
  });
});

describe("stable tweak section columns", () => {
  it("assigns sections alternately as they first appear", () => {
    const ordering = new Map();
    const columns = groupTweaks(
      [tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")],
      "pixel:chatgpt",
      ordering
    );

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([
      ["Colors", "Typography"],
      ["Motion"]
    ]);
  });

  it("keeps sections in their original columns when another section disappears", () => {
    const ordering = new Map();
    const app = "pixel:chatgpt";

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration"), tweak("Typography/Font size")], app, ordering);

    const columns = groupTweaks([tweak("Typography/Font size"), tweak("Colors/Text")], app, ordering);

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Colors", "Typography"], []]);
  });

  it("restores a returning section to its original column", () => {
    const ordering = new Map();
    const app = "pixel:chatgpt";

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

    groupTweaks([tweak("Colors/Text"), tweak("Motion/Duration")], "pixel:chatgpt", ordering);

    const columns = groupTweaks([tweak("Motion/Duration"), tweak("Colors/Text")], "pixel:demo", ordering);

    expect(columns.map((column) => column.map((section) => section.name))).toEqual([["Motion"], ["Colors"]]);
  });
});

function tweak(name: string): TweakDescriptor {
  return {
    name,
    type: "int",
    default: 1,
    value: 1
  };
}

function colorTweak(): TweakDescriptor {
  return {
    name: "Colors/Accent",
    type: "color",
    default: "#5468FF80",
    value: "#5468FF80"
  };
}
