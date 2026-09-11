// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { InspectorHost } from "./index";

function setup() {
  const listeners = new Map<string, (value: unknown) => void>();
  const request = vi.fn(async (command: string, _payload?: unknown): Promise<unknown> => {
    void _payload;
    return command === "hostState" ? { revision: 1, connected: true, baseURL: "http://127.0.0.1:1234/" } : undefined;
  });
  const host = new InspectorHost({
    request: async <T>(command: string, payload?: unknown) => (await request(command, payload)) as T,
    listen: <T>(name: string, callback: (value: T) => void) => {
      listeners.set(name, callback as (value: unknown) => void);
      return () => listeners.delete(name);
    }
  });
  return { host, request, emit: (name: string, value: unknown) => listeners.get(`host:${name}`)?.(value) };
}

describe("shared inspector host", () => {
  it("publishes metadata that arrives while the process remains disconnected", async () => {
    const { host, emit } = setup();
    await host.setToolbar({ start: [] });
    emit("connection", { revision: 2, connected: false });
    const changed = vi.fn();
    host.addEventListener("connection", changed);
    const inspector = { id: "sample", name: "Sample", protocolVersion: 4 };
    const manifest = { version: 1, pid: 10 };
    emit("connection", { revision: 3, connected: false, manifest, inspector });
    expect(changed).toHaveBeenCalledOnce();
    expect(host.connected).toBe(false);
    expect(host.manifest).toEqual(manifest);
    expect(host.inspector).toEqual(inspector);
  });

  it("publishes endpoint changes and ignores old state replies", async () => {
    const { host, emit } = setup();
    const changed = vi.fn();
    host.addEventListener("connection", changed);
    await host.setToolbar({ start: [] });
    expect(host.baseURL).toBe("http://127.0.0.1:1234/");
    emit("connection", { revision: 2, connected: true, baseURL: "http://127.0.0.1:4321/" });
    emit("connection", { revision: 1, connected: false });
    expect(host.connected).toBe(true);
    expect(host.baseURL).toBe("http://127.0.0.1:4321/");
    expect(changed).toHaveBeenCalledTimes(2);
    emit("connection", { revision: 3, connected: true, baseURL: "http://127.0.0.1:4321/" });
    expect(changed).toHaveBeenCalledTimes(3);
  });

  it("places Share at the end and counts search toward the three start controls", async () => {
    const { host, request } = setup();
    const button = (id: string) => ({ type: "button" as const, id, label: id, icon: "clear" as const, onClick() {} });
    const start = [
      button("clear"),
      button("sort"),
      { type: "search" as const, id: "search", label: "Search", value: "", onChange() {} }
    ];
    await host.setToolbar({ start, end: [button("share")] });
    const payload = request.mock.calls.at(-1)![1] as { actions: { placement: string }[] };
    expect(payload.actions.map((action) => action.placement)).toEqual(["start", "start", "start", "end"]);
    await expect(host.setToolbar({ start: [...start, button("fourth")] })).rejects.toThrow("three start");
    await expect(host.setToolbar({ start: [], end: [start[2]] })).rejects.toThrow("end buttons");
  });

  it("ignores queued search input after removing and recreating that action", async () => {
    const { host, request, emit } = setup();
    const changed = vi.fn();
    const search = { type: "search" as const, id: "search", label: "Search", value: "", onChange: changed };
    await host.setToolbar({ start: [search] });
    const old = request.mock.calls.at(-1)![1] as { revision: number };
    await host.setToolbar({ start: [] });
    await host.setToolbar({ start: [search] });
    emit("toolbar", { revision: old.revision, id: "search", value: "old", inputRevision: 1 });
    expect(changed).not.toHaveBeenCalled();
  });

  it("rejects stale picker sessions and colors queued before setValue", async () => {
    const { host, request, emit } = setup();
    const firstChanged = vi.fn(),
      secondChanged = vi.fn(),
      closed = vi.fn();
    const first = await host.openColorPicker({ value: "#112233FF", onChange: firstChanged, onClose: closed });
    const firstSession = request.mock.calls.at(-1)![1] as { sessionId: string };
    const second = await host.openColorPicker({ value: "#445566FF", onChange: secondChanged });
    const session = request.mock.calls.at(-1)![1] as { sessionId: string };
    emit("color-changed", { ...firstSession, revision: 0, color: "#000000FF" });
    expect(firstChanged).not.toHaveBeenCalled();
    expect(closed).toHaveBeenCalledTimes(1);
    await first.close();
    expect(request.mock.calls.at(-1)![0]).toBe("openNativeColorPanel");
    await second.setValue("#778899FF");
    emit("color-changed", { ...session, revision: 0, color: "#000000FF" });
    emit("color-changed", { ...session, revision: 1, color: "#AABBCCFF" });
    expect(secondChanged).toHaveBeenCalledExactlyOnceWith("#AABBCCFF");
    emit("color-closed", firstSession.sessionId);
    await second.close();
    expect(request).toHaveBeenLastCalledWith("closeNativeColorPanel", { sessionId: session.sessionId });
  });

  it("routes toolbar input to current callbacks and rejects stale button events", async () => {
    const { host, request, emit } = setup();
    const oldClick = vi.fn(),
      click = vi.fn(),
      search = vi.fn();
    await host.setToolbar({
      start: [{ type: "button", id: "clear", label: "Clear", icon: "clear", onClick: oldClick }]
    });
    await host.setToolbar({
      start: [
        { type: "button", id: "clear", label: "Clear", icon: "clear", onClick: click },
        { type: "search", id: "search", label: "Search", value: "", onChange: search }
      ]
    });
    const { revision } = request.mock.calls.at(-1)![1] as { revision: number };
    emit("toolbar", { revision: revision - 1, id: "clear" });
    emit("toolbar", { revision, id: "clear" });
    emit("toolbar", { revision, id: "search", value: "query", inputRevision: 1 });
    emit("toolbar", { revision, id: "search", value: "old", inputRevision: 1 });
    expect(oldClick).not.toHaveBeenCalled();
    expect(click).toHaveBeenCalledTimes(1);
    expect(search).toHaveBeenCalledExactlyOnceWith("query");
  });
});
