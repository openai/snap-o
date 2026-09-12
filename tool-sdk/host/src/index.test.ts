// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { ToolHost } from "./index";

const metadata = { manifest: { processIdentity: "boot:42:1" }, inspector: { protocolVersion: 1 } };

function setup() {
  const listeners = new Map<string, (value: unknown) => void>();
  const request = vi.fn(async (command: string, _payload?: unknown): Promise<unknown> => {
    void _payload;
    return command === "hostState"
      ? { ...metadata, revision: 1, connected: true, baseURL: "http://127.0.0.1:1234/" }
      : undefined;
  });
  const host = new ToolHost({
    request: async <T>(command: string, payload?: unknown) => (await request(command, payload)) as T,
    listen: <T>(name: string, callback: (value: T) => void) => {
      listeners.set(name, callback as (value: unknown) => void);
      return () => listeners.delete(name);
    }
  });
  return {
    host,
    request,
    emit: (name: string, value: unknown) =>
      listeners.get(`host:${name}`)?.(name === "connection" ? { ...metadata, ...(value as object) } : value)
  };
}

describe("shared tool host", () => {
  it("keeps discovery objects internal while disconnected", async () => {
    const { host, emit } = setup();
    await host.setToolbar({ actions: [] });
    emit("connection", { revision: 2, connected: false });
    const changed = vi.fn();
    host.addEventListener("connection", changed);
    const tool = { id: "sample", name: "Sample", protocolVersion: 4 };
    const manifest = { version: 1, pid: 10 };
    emit("connection", { revision: 3, connected: false, manifest, inspector: tool });
    expect(changed).toHaveBeenCalledOnce();
    expect(host.connection).toBeNull();
    expect(host).not.toHaveProperty("manifest");
    expect(host).not.toHaveProperty("tool");
  });

  it("waits for connection details and exposes only the fields tools need", async () => {
    const { host, emit } = setup();
    await host.setToolbar({});
    emit("connection", { revision: 2, connected: true, baseURL: "http://127.0.0.1:4321/", manifest: null });
    expect(host.connection).toBeNull();
    emit("connection", { revision: 3, connected: true, baseURL: "http://127.0.0.1:4321/" });
    expect(host.connection).toEqual({
      baseURL: "http://127.0.0.1:4321/",
      protocolVersion: 1,
      processIdentity: "boot:42:1",
      signal: expect.any(AbortSignal)
    });
    expect(host).not.toHaveProperty("connected");
    expect(host).not.toHaveProperty("baseURL");
  });

  it("publishes endpoint changes and ignores old state replies", async () => {
    const { host, emit } = setup();
    const changed = vi.fn();
    host.addEventListener("connection", changed);
    await host.setToolbar({ actions: [] });
    expect(host.connection?.baseURL).toBe("http://127.0.0.1:1234/");
    emit("connection", { revision: 2, connected: true, baseURL: "http://127.0.0.1:4321/" });
    emit("connection", { revision: 1, connected: false });
    expect(host.connection).not.toBeNull();
    expect(host.connection?.baseURL).toBe("http://127.0.0.1:4321/");
    expect(changed).toHaveBeenCalledTimes(2);
    emit("connection", { revision: 3, connected: true, baseURL: "http://127.0.0.1:4321/" });
    expect(changed).toHaveBeenCalledTimes(3);
  });

  it("counts optional search toward the three main controls and keeps end actions separate", async () => {
    const { host, request } = setup();
    const button = (id: string) => ({ id, label: id, icon: "clear" as const, onClick() {} });
    const actions = [button("clear"), button("sort")];
    const search = { label: "Search", value: "", onChange() {} };
    await host.setToolbar({ actions, search, endActions: [button("share")] });
    const payload = request.mock.calls.at(-1)![1] as { actions: { placement: string }[] };
    expect(payload.actions.map((action) => action.placement)).toEqual(["start", "start", "start", "end"]);
    await expect(host.setToolbar({ actions: [...actions, button("third")], search })).rejects.toThrow("three main");
    await host.setToolbar({ actions: [...actions, button("third")] });
    await expect(host.setToolbar({ actions: [button("search")], search })).rejects.toThrow("reserved");
  });

  it("ignores queued search input after removing and recreating search", async () => {
    const { host, request, emit } = setup();
    const changed = vi.fn();
    const search = { label: "Search", value: "", onChange: changed };
    await host.setToolbar({ search });
    const old = request.mock.calls.at(-1)![1] as { revision: number };
    await host.setToolbar({});
    await host.setToolbar({ search });
    emit("toolbar", { revision: old.revision, id: "search", value: "old", inputRevision: 1 });
    expect(changed).not.toHaveBeenCalled();
  });

  it("delivers current connections, cleans up before replacement, and aborts old requests", async () => {
    const { host, emit } = setup();
    await host.setToolbar({});
    const first = host.connection!;
    const order: string[] = [];
    const unsubscribe = host.onConnection((connection) => {
      order.push(connection ? "connected" : "disconnected");
      return () => order.push("cleanup");
    });
    expect(order).toEqual(["connected"]);
    emit("connection", { revision: 2, connected: true, baseURL: first.baseURL });
    expect(host.connection).not.toBe(first);
    expect(first.signal.aborted).toBe(true);
    const second = host.connection!;
    emit("connection", { revision: 3, connected: false });
    expect(second.signal.aborted).toBe(true);
    expect(order).toEqual(["connected", "cleanup", "connected", "cleanup", "disconnected"]);
    unsubscribe();
    unsubscribe();
    emit("connection", { revision: 4, connected: true, baseURL: first.baseURL });
    expect(order).toHaveLength(6);
  });

  it("unsubscribing one UI does not abort another UI's connection", async () => {
    const { host, emit } = setup();
    await host.setToolbar({});
    const connection = host.connection!;
    const cleanup = vi.fn();
    const stop = host.onConnection(() => cleanup);
    const other = vi.fn();
    const stopOther = host.onConnection(other);
    stop();
    expect(connection.signal.aborted).toBe(false);
    emit("connection", { revision: 2, connected: false });
    expect(cleanup).toHaveBeenCalledOnce();
    expect(other).toHaveBeenLastCalledWith(null);
    stopOther();
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
    await host.setToolbar({ actions: [{ id: "clear", label: "Clear", icon: "clear", onClick: oldClick }] });
    await host.setToolbar({
      actions: [{ id: "clear", label: "Clear", icon: "clear", onClick: click }],
      search: { label: "Search", value: "", onChange: search }
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
