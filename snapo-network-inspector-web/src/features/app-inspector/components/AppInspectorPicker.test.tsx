import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { InspectableApp, SelectedAppInspector } from "../../../network/bridge-types";
import { AppInspectorMenu } from "./AppInspectorPicker";

describe("app-first inspector menu", () => {
  it("shows an app once and includes only the inspectors it exposes", () => {
    const markup = renderToStaticMarkup(<AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />);

    expect(markup.match(/class="inspector-app-heading"/g)).toHaveLength(2);
    expect(markup.match(/class="inspector-app-option"/g)).toHaveLength(3);
    expect(markup).toContain("Pixel 9 Pro XL");
    expect(markup).toContain("Android Emulator");
    expect(markup).toContain('title="com.openai.chatgpt"');
    expect(markup).toContain('aria-label="ChatGPT, Network, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="ChatGPT, Tweaks, Pixel 9 Pro XL"');
    expect(markup).toContain('aria-label="Snap-O Tweaks Demo, Tweaks, Android Emulator"');
    expect(markup).not.toContain('aria-label="Snap-O Tweaks Demo, Network');
  });

  it("checks only the selected app and inspector", () => {
    const markup = renderToStaticMarkup(<AppInspectorMenu apps={apps} selection={selection} onSelect={vi.fn()} />);

    expect(markup.match(/aria-checked="true"/g)).toHaveLength(1);
    expect(markup.match(/aria-checked="false"/g)).toHaveLength(2);
  });
});

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
