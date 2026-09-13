// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ToolHost, type ToolConnection } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

const connection: ToolConnection = {
  baseURL: "http://127.0.0.1:1234/",
  processIdentity: "boot:42:1",
  signal: new AbortController().signal
};

function createHost() {
  const host = new ToolHost({ request: async <T,>() => ({}) as T, listen: () => () => {} });
  const current = vi.spyOn(host, "connection", "get").mockReturnValue(connection);
  return { host, current };
}

describe("bundled tool connection", () => {
  let container: HTMLDivElement;
  let latest: ReturnType<typeof useHostConnection>;
  let request: ReturnType<typeof vi.fn<typeof fetch>>;
  function Probe({ host }: { host: ToolHost }) {
    latest = useHostConnection(host);
    return <output>{latest?.processIdentity}</output>;
  }
  async function mount(host: ToolHost) {
    await act(() => render(<Probe host={host} />, container));
  }
  async function publish(target: ReturnType<typeof createHost>, value: ToolConnection | null) {
    await act(() => {
      target.current.mockReturnValue(value);
      target.host.dispatchEvent(new Event("connection"));
    });
  }
  beforeEach(() => {
    container = document.createElement("div");
    request = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", request);
  });
  afterEach(async () => {
    await act(() => render(null, container));
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });
  it("uses the current host connection without making a protocol request", async () => {
    const { host } = createHost();
    await mount(host);
    expect(latest).toBe(connection);
    expect(request).not.toHaveBeenCalled();
  });
  it("returns null while disconnected", async () => {
    const target = createHost();
    target.current.mockReturnValue(null);
    await mount(target.host);
    expect(latest).toBeNull();
    await publish(target, connection);
    expect(latest).toBe(connection);
    await publish(target, null);
    expect(latest).toBeNull();
  });
  it.each(["baseURL", "processIdentity"] as const)("observes a %s change while subscribing", async (property) => {
    const { host, current } = createHost();
    const replacement = { baseURL: "http://127.0.0.1:5678/", processIdentity: "boot:42:2" };
    const subscribe = host.addEventListener.bind(host);
    vi.spyOn(host, "addEventListener").mockImplementationOnce((type, listener, options) => {
      current.mockReturnValue({ ...connection, [property]: replacement[property] });
      subscribe(type, listener, options);
    });
    await mount(host);
    expect(latest).toBe(host.connection);
    expect(latest?.processIdentity).toBe(host.connection?.processIdentity);
  });
  it("observes replacement connections even when their URL and process are unchanged", async () => {
    const target = createHost();
    await mount(target.host);
    const replacement = { ...connection, signal: new AbortController().signal };
    await publish(target, replacement);
    expect(latest).toBe(replacement);
    const nextProcess = { ...replacement, processIdentity: "boot:42:2" };
    await publish(target, nextProcess);
    expect(latest).toBe(nextProcess);
  });
  it("unsubscribes when the host changes or unmounts", async () => {
    const old = createHost();
    await mount(old.host);
    const oldRemove = vi.spyOn(old.host, "removeEventListener");
    const next = createHost();
    const remove = vi.spyOn(next.host, "removeEventListener");
    await mount(next.host);
    expect(oldRemove).toHaveBeenCalledWith("connection", expect.any(Function));
    const state = latest;
    await publish(old, null);
    expect(latest).toBe(state);
    await act(() => render(null, container));
    expect(remove).toHaveBeenCalledWith("connection", expect.any(Function));
  });
});
