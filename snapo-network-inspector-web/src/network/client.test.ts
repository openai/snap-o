import { afterEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient } from "./client";

afterEach(() => vi.unstubAllGlobals());

describe("native app launch bridge", () => {
  it("asks the host to open its selected app", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    stubNativeBridge(postMessage);
    const client = createNetworkClient();
    await expect(client.openSelectedApp("phone:pid:20")).resolves.toBeUndefined();
    expect(postMessage).toHaveBeenCalledWith({
      command: "openSelectedApp",
      payload: { appId: "phone:pid:20" }
    });
  });

  it("propagates native launch failures", async () => {
    stubNativeBridge(vi.fn().mockRejectedValue(new Error("Device is offline.")));
    await expect(createNetworkClient().openSelectedApp("phone:pid:20")).rejects.toThrow("Device is offline.");
  });
});

it("requires the native host instead of falling back to HTTP", () => {
  vi.stubGlobal("window", {});
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);

  expect(() => createNetworkClient()).toThrow("Open this inspector in the Snap-O macOS app.");
  expect(fetch).not.toHaveBeenCalled();
});

describe("native persistent exclusion filter bridge", () => {
  it("explicitly restores conventional exclusion filters instead of relying on an early page event", async () => {
    const postMessage = vi.fn().mockResolvedValue(["-example.com", "-statsig.com"]);
    stubNativeBridge(postMessage);

    const client = createNetworkClient();

    await expect(client.listExclusionFilters()).resolves.toEqual(["-example.com", "-statsig.com"]);
    expect(postMessage).toHaveBeenCalledWith({ command: "listExclusionFilters", payload: undefined });
  });

  it("persists a right-clicked exclusion filter through the native application", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    stubNativeBridge(postMessage);

    const client = createNetworkClient();

    await expect(client.addExclusionFilter("-api.example.com")).resolves.toBeUndefined();
    expect(postMessage).toHaveBeenCalledWith({
      command: "addExclusionFilter",
      payload: { filter: "-api.example.com" }
    });
  });

  it("removes exclusion filters through the native application", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    stubNativeBridge(postMessage);

    const client = createNetworkClient();

    await expect(client.removeExclusionFilter("-api.example.com")).resolves.toBeUndefined();
    expect(postMessage).toHaveBeenCalledWith({
      command: "removeExclusionFilter",
      payload: { filter: "-api.example.com" }
    });
  });
});

function stubNativeBridge(postMessage: ReturnType<typeof vi.fn>): void {
  vi.stubGlobal("window", {
    webkit: {
      messageHandlers: {
        snapoNetwork: { postMessage }
      }
    }
  });
}
