import { describe, expect, it } from "vitest";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "../../network/bridge-types";
import { isInspectorMetadataPending } from "./selection";

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

describe("inspector metadata", () => {
  const processApp = { ...app, id: "pixel:pid:10" };
  const current: SelectedAppInspector = { appId: processApp.id, ...tweaks };
  it("waits for the native Tweaks protocol version before enabling controls", () => {
    const pending = { ...current, protocolVersion: undefined };
    expect(isInspectorMetadataPending(pending, true)).toBe(true);
    expect(isInspectorMetadataPending(current, true)).toBe(false);
    expect(isInspectorMetadataPending({ ...current, protocolVersion: 1 }, true)).toBe(false);
    expect(isInspectorMetadataPending({ appId: processApp.id, ...network }, true)).toBe(false);
    expect(isInspectorMetadataPending(pending, false)).toBe(false);
  });
});
