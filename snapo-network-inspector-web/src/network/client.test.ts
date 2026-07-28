import { afterEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient } from "./client";

afterEach(() => vi.unstubAllGlobals());

describe("native persistent host filter bridge", () => {
  it("explicitly restores hidden hosts instead of relying on an early page event", async () => {
    const postMessage = vi.fn().mockResolvedValue(["example.com", "statsig.com"]);
    stubNativeBridge(postMessage);

    const client = createNetworkClient();

    await expect(client.listHiddenHosts()).resolves.toEqual(["example.com", "statsig.com"]);
    expect(postMessage).toHaveBeenCalledWith({ command: "listHiddenHosts", payload: undefined });
  });

  it("persists a right-clicked host through the native application", async () => {
    const postMessage = vi.fn().mockResolvedValue(undefined);
    stubNativeBridge(postMessage);

    const client = createNetworkClient();

    await expect(client.addHiddenHost("api.example.com")).resolves.toBeUndefined();
    expect(postMessage).toHaveBeenCalledWith({
      command: "addHiddenHost",
      payload: { host: "api.example.com" }
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
