import { Children, isValidElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { InspectableApp, SelectedAppInspector } from "../../../network/bridge-types";
import { AppInspectorMenu, AppInspectorPicker, AppInspectorViewPicker } from "./AppInspectorPicker";

describe("app-first inspector menu", () => {
  it("keeps the remembered inspector controls visible offline without a spinner", () => {
    const markup = renderToStaticMarkup(
      <AppInspectorPicker apps={[]} selection={null} selectedApp={apps[0]} preferredKind="tweaks" onSelect={vi.fn()} />
    );
    expect(markup).not.toContain("body-loading-spinner");
    expect(markup).toContain('aria-label="Network" aria-checked="false"');
    expect(markup).toContain('aria-label="Tweaks" aria-checked="true"');
    expect(markup).toContain(apps[0].name);
  });

  it("uses cached types instead of a partial live app in the toolbar", () => {
    const partial = { ...apps[0], inspectors: [apps[0].inspectors[1]] };
    const markup = renderToStaticMarkup(
      <AppInspectorPicker apps={[partial]} selection={selection} selectedApp={apps[0]} onSelect={vi.fn()} />
    );
    expect(markup).toContain('aria-label="Network"');
    expect(markup).toContain('aria-label="Tweaks"');
  });
  it("shows one selectable row per app without separate inspector rows", () => {
    const markup = renderToStaticMarkup(<AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />);

    expect(markup.match(/class="inspector-app-option"/g)).toHaveLength(2);
    expect(markup.match(/class="inspector-app-row"/g)).toHaveLength(2);
    expect(markup.match(/class="inspector-app-shortcut"/g)).toHaveLength(3);
    expect(markup).toContain("Pixel 9 Pro XL");
    expect(markup).toContain("Android Emulator");
    expect(markup).toContain('title="com.openai.chatgpt"');
    expect(markup).toContain('aria-label="ChatGPT, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="Snap-O Tweaks Demo, Android Emulator"');
    expect(markup).not.toContain('aria-label="ChatGPT, Network');
    expect(markup).not.toContain('aria-label="ChatGPT, Tweaks');
    expect(markup).toContain('aria-label="Open Network for ChatGPT, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="Open Tweaks for ChatGPT, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="Open Tweaks for Snap-O Tweaks Demo, Android Emulator"');
    expect(markup).not.toContain('aria-label="Open Network for Snap-O Tweaks Demo');
    for (const button of markup.match(/<button\b[^>]*>[\s\S]*?<\/button>/g) ?? []) {
      expect(button.match(/<button\b/g)).toHaveLength(1);
    }
  });

  it("opens the exact inspector when its shortcut is clicked", () => {
    const onSelect = vi.fn();
    const buttons = menuButtons(AppInspectorMenu({ apps, selection, onSelect }));

    buttons.get("Open Network for ChatGPT, Pixel 9 Pro XL")!();

    expect(onSelect).toHaveBeenCalledExactlyOnceWith(apps[0], apps[0].inspectors[0]);

    onSelect.mockClear();
    buttons.get("Open Tweaks for Snap-O Tweaks Demo, Android Emulator")!();

    expect(onSelect).toHaveBeenCalledExactlyOnceWith(apps[1], apps[1].inspectors[0]);
  });

  it("places the selection check before the app icon and keeps shortcuts on the right", () => {
    const markup = renderToStaticMarkup(<AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />);
    const rows = markup.split('class="inspector-app-row"').slice(1);

    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const check = row.indexOf("inspector-app-option-check");
      const appIcon = row.indexOf('class="inspector-app-icon"');
      const shortcuts = row.indexOf('class="inspector-app-shortcuts"');
      expect(check).toBeGreaterThan(-1);
      expect(appIcon).toBeGreaterThan(check);
      expect(shortcuts).toBeGreaterThan(appIcon);
    }
  });

  it("delegates an app-row choice to the selection owner", () => {
    const onSelect = vi.fn();
    const otherAppSelection = { appId: apps[1].id, ...apps[1].inspectors[0] };
    const buttons = menuButtons(AppInspectorMenu({ apps, selection: otherAppSelection, onSelect }));

    buttons.get("ChatGPT, Pixel 9 Pro XL")!();

    expect(onSelect).toHaveBeenCalledExactlyOnceWith(apps[0]);
  });

  it("delegates a single-inspector app choice to the selection owner", () => {
    const onSelect = vi.fn();
    const networkSelection = { appId: apps[0].id, ...apps[0].inspectors[0] };
    const buttons = menuButtons(AppInspectorMenu({ apps, selection: networkSelection, onSelect }));

    buttons.get("Snap-O Tweaks Demo, Android Emulator")!();

    expect(onSelect).toHaveBeenCalledExactlyOnceWith(apps[1]);
  });

  it("checks only the selected app", () => {
    const markup = renderToStaticMarkup(<AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />);

    expect(markup.match(/aria-checked="true"/g)).toHaveLength(1);
    expect(markup.match(/aria-checked="false"/g)).toHaveLength(1);
  });

  it("keeps the same app checked when its inspector changes", () => {
    const networkSelection = { appId: apps[0].id, ...apps[0].inspectors[0] };
    const tweaksMarkup = renderToStaticMarkup(
      <AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />
    );
    const networkMarkup = renderToStaticMarkup(
      <AppInspectorMenu apps={apps} selection={networkSelection} onSelect={vi.fn()} />
    );

    expect(networkMarkup).toBe(tweaksMarkup);
  });

  it("keeps the same package on different devices as separate apps", () => {
    const otherDevice: InspectableApp = {
      ...apps[0],
      id: "emulator:com.openai.chatgpt",
      deviceId: "emulator",
      deviceDisplayTitle: "Android Emulator",
      inspectors: apps[0].inspectors.map((option) => ({
        ...option,
        server: { ...option.server, deviceId: "emulator" }
      }))
    };
    const markup = renderToStaticMarkup(
      <AppInspectorMenu apps={[apps[0], otherDevice]} selection={selection} onSelect={vi.fn()} />
    );

    expect(markup.match(/class="inspector-app-option"/g)).toHaveLength(2);
    expect(markup).toContain('aria-label="ChatGPT, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="ChatGPT, Android Emulator"');
    expect(markup.match(/aria-checked="true"/g)).toHaveLength(1);
  });

  it("disables apps without an available inspector", () => {
    const markup = renderToStaticMarkup(
      <AppInspectorMenu apps={[{ ...apps[0], inspectors: [] }]} selection={null} onSelect={vi.fn()} />
    );

    expect(markup).toContain('disabled=""');
  });

  it("shows only the app name in the picker button", () => {
    const markup = renderToStaticMarkup(<AppInspectorPicker apps={apps} selection={selection} onSelect={vi.fn()} />);

    expect(markup).toContain('class="inspector-app-picker-name">ChatGPT</span>');
    expect(markup).toContain('aria-label="Select an app"');
    expect(markup).not.toContain("ChatGPT · Tweaks");
    expect(markup).not.toContain("ChatGPT · Network");
  });

  it("shows a selectable icon group when an app exposes both inspectors", () => {
    const markup = renderToStaticMarkup(
      <AppInspectorViewPicker app={apps[0]} selection={selection} onSelect={vi.fn()} />
    );

    expect(markup).toContain('role="radiogroup"');
    expect(markup.match(/class="inspector-app-segment"/g)).toHaveLength(2);
    expect(markup).toMatch(/aria-label="Network" aria-checked="false"/);
    expect(markup).toMatch(/aria-label="Tweaks" aria-checked="true"/);
    expect(markup).not.toContain(">Network</button>");
    expect(markup).not.toContain(">Tweaks</button>");
  });

  it("hides the icon group when only one inspector is available", () => {
    const markup = renderToStaticMarkup(
      <AppInspectorViewPicker app={apps[1]} selection={selection} onSelect={vi.fn()} />
    );

    expect(markup).toBe("");
  });
});

function menuButtons(tree: ReactNode): Map<string, () => void> {
  const buttons = new Map<string, () => void>();
  const visit = (node: ReactNode) => {
    Children.forEach(node, (child) => {
      if (!isValidElement<{ children?: ReactNode; "aria-label"?: string; onClick?: () => void }>(child)) return;
      const { children, "aria-label": label, onClick } = child.props;
      if (child.type === "button" && label && onClick) buttons.set(label, onClick);
      visit(children);
    });
  };
  visit(tree);
  return buttons;
}

const apps: InspectableApp[] = [
  {
    id: "pixel:com.openai.chatgpt",
    name: "ChatGPT",
    packageName: "com.openai.chatgpt",
    deviceId: "pixel",
    deviceDisplayTitle: "Pixel 9 Pro XL",
    inspectors: [
      { kind: "network", server: { deviceId: "pixel", socketName: "snapo_network_10" } },
      { kind: "tweaks", server: { deviceId: "pixel", socketName: "snapo_tweaks_10" } }
    ]
  },
  {
    id: "emulator:com.openai.snapo.demo.tweaks",
    name: "Snap-O Tweaks Demo",
    packageName: "com.openai.snapo.demo.tweaks",
    deviceId: "emulator",
    deviceDisplayTitle: "Android Emulator",
    inspectors: [{ kind: "tweaks", server: { deviceId: "emulator", socketName: "snapo_tweaks_20" } }]
  }
];

const selection: SelectedAppInspector = {
  appId: "pixel:com.openai.chatgpt",
  kind: "tweaks",
  server: { deviceId: "pixel", socketName: "snapo_tweaks_10" }
};
