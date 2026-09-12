// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Host, ToolConnection } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

const connection: ToolConnection = {
  baseURL: "http://127.0.0.1:1234/",
  protocolVersion: 1,
  processIdentity: "boot:42:1",
  signal: new AbortController().signal
};

function createHost(): Host {
  const host = Object.assign(new EventTarget(), {
    connection,
    onConnection(callback: (connection: ToolConnection | null) => void) {
      const update = () => callback(host.connection);
      host.addEventListener("connection", update);
      update();
      return () => host.removeEventListener("connection", update);
    }
  }) as Host;
  return host;
}

describe("host connection snapshots", () => {
  let container: HTMLDivElement;
  let latest: ReturnType<typeof useHostConnection> & Pick<Host, "connection">;

  function Probe({ host }: { host: Host }) {
    const connection = useHostConnection(host);
    latest = { ...connection, connection: host.connection };
    return <output>{latest.connection?.baseURL}</output>;
  }

  beforeEach(() => {
    container = document.createElement("div");
  });
  afterEach(async () => {
    await act(() => render(null, container));
    vi.restoreAllMocks();
  });

  it.each(["baseURL", "processIdentity", "protocolVersion"] as const)(
    "observes a %s change between rendering and subscribing",
    async (property) => {
      const host = createHost();
      const replacement = {
        baseURL: "http://127.0.0.1:5678/",
        processIdentity: "boot:42:2",
        protocolVersion: 2
      };
      const subscribe = host.addEventListener.bind(host);
      vi.spyOn(host, "addEventListener").mockImplementationOnce((type, listener, options) => {
        Object.assign(host, { connection: { ...connection, [property]: replacement[property] } });
        subscribe(type, listener, options);
      });
      await act(() => render(<Probe host={host} />, container));
      expect(latest.connected).toBe(true);
      expect(latest.connection?.[property]).toBe(replacement[property]);
      expect(latest.revision).toBeGreaterThan(0);
    }
  );

  it("updates on address and metadata changes", async () => {
    const host = createHost();
    await act(() => render(<Probe host={host} />, container));
    const initial = latest;

    await act(() => {
      Object.assign(host, {
        connection: {
          ...connection,
          baseURL: "http://127.0.0.1:5678/",
          processIdentity: "boot:42:2",
          protocolVersion: 2
        }
      });
      host.dispatchEvent(new Event("connection"));
    });
    expect(latest.connected).toBe(true);
    expect(latest.connection?.baseURL).toBe("http://127.0.0.1:5678/");
    expect(latest.connection?.processIdentity).toBe("boot:42:2");
    expect(latest.connection?.protocolVersion).toBe(2);
    expect(latest.revision).toBe(initial.revision + 1);
  });

  it("preserves a new connection event when the host fields are unchanged", async () => {
    const host = createHost();
    await act(() => render(<Probe host={host} />, container));
    const initialRevision = latest.revision;
    await act(() => {
      host.dispatchEvent(new Event("connection"));
    });
    expect(latest.revision).toBe(initialRevision + 1);
  });

  it("observes disconnect and reconnect at the same address", async () => {
    const host = createHost();
    await act(() => render(<Probe host={host} />, container));
    const initialRevision = latest.revision;
    for (const connected of [false, true]) {
      await act(() => {
        Object.assign(host, { connection: connected ? connection : null });
        host.dispatchEvent(new Event("connection"));
      });
      expect(latest.connected).toBe(connected);
    }
    expect(latest.revision).toBe(initialRevision + 2);
  });

  it("unsubscribes when the host changes and when the component unmounts", async () => {
    const oldHost = createHost();
    const newHost = createHost();
    const oldRemove = vi.spyOn(oldHost, "removeEventListener");
    const newRemove = vi.spyOn(newHost, "removeEventListener");
    await act(() => render(<Probe host={oldHost} />, container));
    await act(() => render(<Probe host={newHost} />, container));
    expect(oldRemove).toHaveBeenCalledWith("connection", expect.any(Function));
    const current = latest;
    await act(() => {
      Object.assign(oldHost, { connection: null });
      oldHost.dispatchEvent(new Event("connection"));
    });
    expect(latest).toBe(current);
    await act(() => render(null, container));
    expect(newRemove).toHaveBeenCalledWith("connection", expect.any(Function));
  });
});
