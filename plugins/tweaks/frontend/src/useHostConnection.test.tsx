// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Host, PluginDescriptor, ProcessManifest } from "@snap-o/plugin-host";
import { useHostConnection } from "./useHostConnection";

const plugin: PluginDescriptor = { id: "example", name: "Example", protocolVersion: 1 };
const manifest: ProcessManifest = {
  version: 1,
  pid: 42,
  processIdentity: "boot:42:1",
  app: { packageName: "com.example.app", name: "Example", revision: "1", inspectors: [plugin] }
};

function createHost(): Host {
  return Object.assign(new EventTarget(), {
    connected: true,
    baseURL: "http://127.0.0.1:1234/",
    manifest,
    plugin
  }) as Host;
}

describe("host connection snapshots", () => {
  let container: HTMLDivElement;
  let latest: ReturnType<typeof useHostConnection> & Pick<Host, "baseURL" | "manifest" | "plugin">;

  function Probe({ host }: { host: Host }) {
    const connection = useHostConnection(host);
    latest = { ...connection, baseURL: host.baseURL, manifest: host.manifest, plugin: host.plugin };
    return (
      <output>
        {latest.baseURL} {latest.manifest?.app.name} {latest.plugin?.name}
      </output>
    );
  }

  beforeEach(() => {
    container = document.createElement("div");
  });
  afterEach(async () => {
    await act(() => render(null, container));
    vi.restoreAllMocks();
  });

  it.each(["baseURL", "manifest", "plugin"] as const)(
    "observes a %s change between rendering and subscribing",
    async (property) => {
      const host = createHost();
      const replacement = {
        baseURL: "http://127.0.0.1:5678/",
        manifest: { ...manifest, app: { ...manifest.app, name: "Updated app" } },
        plugin: { ...plugin, name: "Updated tool" }
      };
      const subscribe = host.addEventListener.bind(host);
      vi.spyOn(host, "addEventListener").mockImplementationOnce((type, listener, options) => {
        Object.assign(host, { [property]: replacement[property] });
        subscribe(type, listener, options);
      });
      await act(() => render(<Probe host={host} />, container));
      expect(latest.connected).toBe(true);
      expect(latest[property]).toBe(replacement[property]);
      expect(latest.revision).toBeGreaterThan(0);
    }
  );

  it("updates on address and metadata changes", async () => {
    const host = createHost();
    await act(() => render(<Probe host={host} />, container));
    const initial = latest;

    await act(() => {
      Object.assign(host, {
        baseURL: "http://127.0.0.1:5678/",
        manifest: { ...manifest, processIdentity: "boot:42:2" },
        plugin: { ...plugin, protocolVersion: 2 }
      });
      host.dispatchEvent(new Event("connection"));
    });
    expect(latest.connected).toBe(true);
    expect(latest.baseURL).toBe("http://127.0.0.1:5678/");
    expect(latest.manifest?.processIdentity).toBe("boot:42:2");
    expect(latest.plugin?.protocolVersion).toBe(2);
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
        Object.assign(host, { connected });
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
      Object.assign(oldHost, { connected: false });
      oldHost.dispatchEvent(new Event("connection"));
    });
    expect(latest).toBe(current);
    await act(() => render(null, container));
    expect(newRemove).toHaveBeenCalledWith("connection", expect.any(Function));
  });
});
