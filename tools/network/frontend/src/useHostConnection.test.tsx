// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Host, ToolConnection } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

const connection: ToolConnection = {
  baseURL: "http://127.0.0.1:1234/",
  processIdentity: "boot:42:1",
  signal: new AbortController().signal
};

function createHost(): Host {
  const host = Object.assign(new EventTarget(), {
    connection: connection as ToolConnection | null,
    onConnection(callback: (connection: ToolConnection | null) => void) {
      const update = () => callback(host.connection);
      host.addEventListener("connection", update);
      update();
      return () => host.removeEventListener("connection", update);
    }
  }) as Host;
  return host;
}

describe("tool protocol connection", () => {
  let container: HTMLDivElement;
  let latest: ReturnType<typeof useHostConnection>;
  let request: ReturnType<typeof vi.fn<typeof fetch>>;
  function Probe({ host }: { host: Host }) {
    latest = useHostConnection(host);
    return <output>{latest.metadata?.protocolVersion}</output>;
  }
  async function mount(host = createHost()) {
    await act(() => render(<Probe host={host} />, container));
    return host;
  }
  async function publish(host: Host, value: ToolConnection | null) {
    await act(() => {
      Object.assign(host, { connection: value });
      host.dispatchEvent(new Event("connection"));
    });
  }
  beforeEach(() => {
    container = document.createElement("div");
    request = vi.fn<typeof fetch>(async () => Response.json({ version: 4 }));
    vi.stubGlobal("fetch", request);
  });
  afterEach(async () => {
    await act(() => render(null, container));
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });
  it("reads the tool protocol before connecting", async () => {
    let resolve!: (response: Response) => void;
    request.mockImplementationOnce(
      () =>
        new Promise((done) => {
          resolve = done;
        })
    );
    await mount();
    expect(latest.connected).toBe(false);
    expect(request).toHaveBeenCalledWith(new URL("http://127.0.0.1:1234/network/protocol"), {
      signal: expect.any(AbortSignal)
    });
    await act(async () => resolve(Response.json({ version: 4 })));
    await vi.waitFor(() => expect(latest.connected).toBe(true));
    expect(latest.metadata).toEqual({ protocolVersion: 4, processIdentity: "boot:42:1" });
  });
  it.each(["baseURL", "processIdentity"] as const)("observes a %s change while subscribing", async (property) => {
    const host = createHost();
    const replacement = { baseURL: "http://127.0.0.1:5678/", processIdentity: "boot:42:2" };
    const subscribe = host.addEventListener.bind(host);
    vi.spyOn(host, "addEventListener").mockImplementationOnce((type, listener, options) => {
      Object.assign(host, { connection: { ...connection, [property]: replacement[property] } });
      subscribe(type, listener, options);
    });
    await mount(host);
    await vi.waitFor(() => expect(latest.connected).toBe(true));
    expect(String(request.mock.calls[0][0])).toBe(new URL("network/protocol", host.connection!.baseURL).href);
    expect(latest.metadata?.processIdentity).toBe(host.connection?.processIdentity);
  });
  it("preserves cached metadata offline and checks each reconnect", async () => {
    const host = await mount();
    await vi.waitFor(() => expect(latest.connected).toBe(true));
    const metadata = latest.metadata;
    await publish(host, null);
    expect(latest.connected).toBe(false);
    expect(latest.metadata).toEqual(metadata);
    request.mockResolvedValueOnce(Response.json({ version: 4 + 1 }));
    await publish(host, connection);
    await vi.waitFor(() => expect(latest.metadata?.protocolVersion).toBe(4 + 1));
    expect(request).toHaveBeenCalledTimes(2);
  });
  it("ignores a late reply from a replaced connection", async () => {
    let resolve!: (response: Response) => void;
    request.mockImplementationOnce(
      () =>
        new Promise((done) => {
          resolve = done;
        })
    );
    const host = await mount();
    const signal = request.mock.calls[0][1]!.signal!;
    await publish(host, { ...connection, processIdentity: "boot:42:2" });
    await vi.waitFor(() => expect(latest.connected).toBe(true));
    expect(signal.aborted).toBe(true);
    await act(async () => resolve(Response.json({ version: 4 + 1 })));
    expect(latest.metadata).toEqual({ protocolVersion: 4, processIdentity: "boot:42:2" });
  });
  it.each([{}, { version: "4" }, { version: true }, { version: 0 }, { version: 1.5 }])(
    "rejects invalid protocol data %j",
    async (payload) => {
      request.mockResolvedValueOnce(Response.json(payload));
      await mount();
      await vi.waitFor(() => expect(latest.error).toContain("invalid"));
      expect(latest.connected).toBe(false);
    }
  );
  it("reports an unavailable endpoint without starting tool operations", async () => {
    request.mockResolvedValueOnce(new Response(null, { status: 404 }));
    await mount();
    await vi.waitFor(() => expect(latest.error).toContain("404"));
    expect(latest.connected).toBe(false);
  });
  it("cancels requests and unsubscribes when the host changes or unmounts", async () => {
    request.mockImplementation(() => new Promise(() => {}));
    const oldHost = await mount();
    const oldRemove = vi.spyOn(oldHost, "removeEventListener");
    const oldSignal = request.mock.calls[0][1]!.signal!;
    const next = createHost();
    const remove = vi.spyOn(next, "removeEventListener");
    await mount(next);
    expect(oldSignal.aborted).toBe(true);
    expect(oldRemove).toHaveBeenCalledWith("connection", expect.any(Function));
    const current = latest;
    await publish(oldHost, null);
    expect(latest).toBe(current);
    await act(() => render(null, container));
    expect(request.mock.calls[1][1]!.signal!.aborted).toBe(true);
    expect(remove).toHaveBeenCalledWith("connection", expect.any(Function));
  });
});
