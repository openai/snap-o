import { describe, expect, it } from "vitest";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "../../network/bridge-types";
import { isInspectorMetadataPending, preferredInspector, reconcileInspectorSelection } from "./selection";

const network: AppInspectorOption = {
  kind: "network",
  server: { deviceId: "pixel", socketName: "snapo_network_10" }
};
const tweaks: AppInspectorOption = {
  kind: "tweaks",
  server: { deviceId: "pixel", socketName: "snapo_tweaks_10" },
  protocolVersion: 2
};
const app: InspectableApp = {
  id: "pixel:com.openai.chatgpt",
  name: "ChatGPT",
  packageName: "com.openai.chatgpt",
  deviceId: "pixel",
  deviceDisplayTitle: "Pixel 9",
  inspectors: [network, tweaks]
};

describe("preferred app inspector", () => {
  it("preserves the exact endpoint when reselecting the current app", () => {
    const anotherTweaks: AppInspectorOption = {
      ...tweaks,
      server: { ...tweaks.server, socketName: "snapo_tweaks_20" }
    };
    const selection: SelectedAppInspector = { appId: app.id, ...anotherTweaks };

    expect(preferredInspector({ ...app, inspectors: [network, tweaks, anotherTweaks] }, selection)).toBe(anotherTweaks);
  });

  it("preserves the inspector kind when switching apps", () => {
    const selection: SelectedAppInspector = {
      appId: "emulator:other.app",
      kind: "tweaks",
      server: { deviceId: "emulator", socketName: "other_tweaks" }
    };

    expect(preferredInspector(app, selection)).toBe(tweaks);
  });

  it("falls back to an available inspector when the kind is unsupported", () => {
    expect(preferredInspector({ ...app, inspectors: [network] }, { appId: app.id, ...tweaks })).toBe(network);
    expect(preferredInspector({ ...app, inspectors: [tweaks] }, { appId: app.id, ...network })).toBe(tweaks);
  });

  it("uses the first inspector when there is no current selection", () => {
    expect(preferredInspector(app, null)).toBe(network);
  });

  it("uses the refreshed endpoint when the selected endpoint disappears", () => {
    const selection: SelectedAppInspector = {
      appId: app.id,
      kind: "tweaks",
      server: { ...tweaks.server, socketName: "old_tweaks" }
    };

    expect(preferredInspector(app, selection)).toBe(tweaks);
  });

  it("returns no option when an app has no inspectors", () => {
    expect(preferredInspector({ ...app, inspectors: [] }, null)).toBeUndefined();
  });
});

describe("discovered inspector selection", () => {
  const processApp = { ...app, id: "pixel:pid:10" };
  const current: SelectedAppInspector = { appId: processApp.id, ...tweaks };

  it("preserves selection while app names, icons, and other inspectors load", () => {
    const discovered = { ...processApp, name: "Loaded app", appIconBase64: "icon" };
    expect(reconcileInspectorSelection([discovered], current)).toBe(current);
  });

  it("updates the selected protocol version after metadata loads", () => {
    const pending = { ...current, protocolVersion: undefined };
    expect(reconcileInspectorSelection([processApp], pending)).toEqual(current);
  });

  it("finds the same endpoint when replacing an old package-based ID", () => {
    const legacy = { ...current, appId: app.id };
    expect(reconcileInspectorSelection([processApp], legacy)).toEqual(current);
  });

  it("keeps the process selected if one inspector disappears", () => {
    const remaining = { ...processApp, inspectors: [network] };
    expect(reconcileInspectorSelection([remaining], current)).toEqual({ appId: processApp.id, ...network });
  });

  it("falls back when the process exits", () => {
    const next = { ...app, id: "pixel:pid:20", inspectors: [network] };
    expect(reconcileInspectorSelection([next], current)).toEqual({ appId: next.id, ...network });
    expect(reconcileInspectorSelection([], current)).toBeNull();
  });

  it("waits for the native Tweaks protocol version before enabling controls", () => {
    const pending = { ...current, protocolVersion: undefined };
    expect(isInspectorMetadataPending(pending, true)).toBe(true);
    expect(isInspectorMetadataPending(current, true)).toBe(false);
    expect(isInspectorMetadataPending({ ...current, protocolVersion: 1 }, true)).toBe(false);
    expect(isInspectorMetadataPending({ appId: processApp.id, ...network }, true)).toBe(false);
    expect(isInspectorMetadataPending(pending, false)).toBe(false);
  });
});
