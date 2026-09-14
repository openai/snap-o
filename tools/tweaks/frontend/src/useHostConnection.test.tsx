// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { expect, it, vi } from "vitest";
import { ToolHost, type ToolConnection } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

it("renders connection changes and releases subscriptions when replaced or unmounted", async () => {
  const connection: ToolConnection = {
    baseURL: "http://127.0.0.1:1234/",
    processIdentity: "boot:42:1",
    signal: new AbortController().signal
  };
  const first = new ToolHost({ request: async <T,>() => ({}) as T, listen: () => () => {} });
  const second = new ToolHost({ request: async <T,>() => ({}) as T, listen: () => () => {} });
  const current = vi.spyOn(first, "connection", "get").mockReturnValue(connection);
  const firstRemove = vi.spyOn(first, "removeEventListener");
  const secondRemove = vi.spyOn(second, "removeEventListener");
  const container = document.createElement("div");
  function Probe({ host }: { host: ToolHost }) {
    const value = useHostConnection(host);
    return <output>{value?.processIdentity ?? "disconnected"}</output>;
  }
  try {
    await act(() => render(<Probe host={first} />, container));
    expect(container.textContent).toBe(connection.processIdentity);
    await act(() => {
      current.mockReturnValue(null);
      first.dispatchEvent(new Event("connection"));
    });
    expect(container.textContent).toBe("disconnected");
    await act(() => {
      current.mockReturnValue(connection);
      first.dispatchEvent(new Event("connection"));
    });
    expect(container.textContent).toBe(connection.processIdentity);
    await act(() => render(<Probe host={second} />, container));
    expect(container.textContent).toBe("disconnected");
    expect(firstRemove).toHaveBeenCalledWith("connection", expect.any(Function));
    await act(() => render(null, container));
    expect(secondRemove).toHaveBeenCalledWith("connection", expect.any(Function));
  } finally {
    await act(() => render(null, container));
    vi.restoreAllMocks();
  }
});
