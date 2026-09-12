// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNetworkClient, type NetworkClient } from "./client";
import { host } from "@snap-o/tool-host";

describe("browser network client", () => {
  let client: NetworkClient;
  beforeEach(() => {
    const values = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      clear: () => values.clear()
    });
    localStorage.clear();
    vi.spyOn(host, "addEventListener").mockImplementation(() => {});
    client = createNetworkClient();
  });
  afterEach(() => {
    client?.dispose();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });
  it("persists exclusion filters without losing concurrent edits", async () => {
    await Promise.all([client.addExclusionFilter("-one.test"), client.addExclusionFilter("-two.test")]);
    const second = createNetworkClient();
    expect(await second.listExclusionFilters()).toEqual(["-one.test", "-two.test"]);
    second.dispose();
    await client.removeExclusionFilter("-one.test");
    expect(await client.listExclusionFilters()).toEqual(["-two.test"]);
    localStorage.setItem("network.exclusionFilters", "invalid");
    expect(await client.listExclusionFilters()).toEqual([]);
  });
  it("uses the shared host for clipboard and file export", async () => {
    const copy = vi.spyOn(host, "copyText").mockResolvedValue();
    const save = vi.spyOn(host, "saveFile").mockResolvedValue(true);
    await client.copyText("request");
    expect(copy).toHaveBeenCalledWith("request");
    expect(
      await client.saveFile({ defaultPath: "capture.har", data: "{}", encoding: "utf8", mimeType: "application/json" })
    ).toEqual({ saved: true });
    expect(save).toHaveBeenCalledWith({ name: "capture.har", data: expect.any(Blob) });
  });
  it("rejects requests while disconnected", async () => {
    vi.spyOn(host, "connection", "get").mockReturnValue(null);
    await expect(
      client.startStream({
        protocolVersion: 4,
        processIdentity: "boot:20:123"
      })
    ).rejects.toThrow("disconnected");
    await expect(client.loadBodies({ processId: "process-1", requestId: "one" })).rejects.toThrow("disconnected");
  });
});
