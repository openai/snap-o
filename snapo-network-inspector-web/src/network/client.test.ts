import { afterEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient } from "./client";

afterEach(() => vi.unstubAllGlobals());

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
