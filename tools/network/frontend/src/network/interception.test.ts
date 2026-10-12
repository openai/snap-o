import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { observeInterception, type InterceptionState } from "./interception";

class Events extends EventTarget {
  readyState = 0;
  close = vi.fn();
  send(runners: unknown[]) {
    this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify({ runners }) }));
  }
}

const runner = {
  id: "runner-1",
  routes: [{ id: "items", method: "GET", path: "/items" }]
};

describe("read-only interception observer", () => {
  let stream: Events;
  let open: ReturnType<typeof vi.fn<(url: string) => void>>;
  let dispose: () => void;
  let abort: AbortController;
  let received: InterceptionState[];

  beforeEach(() => {
    vi.useFakeTimers();
    stream = new Events();
    open = vi.fn();
    vi.stubGlobal(
      "EventSource",
      class {
        static readonly CLOSED = 2;
        constructor(url: string) {
          open(url);
          return stream;
        }
      }
    );
    abort = new AbortController();
    received = [];
    dispose = observeInterception({ signal: abort.signal, processIdentity: "process-1" }, (state) =>
      received.push(state)
    );
  });

  afterEach(() => {
    dispose();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("replaces registrations after reload and recovers native retries without stale routes", () => {
    expect(open).toHaveBeenCalledExactlyOnceWith("/api/interception");
    expect(received).toEqual([{ status: "connecting" }]);
    stream.send([runner]);
    expect(received.at(-1)).toEqual({ status: "live", runners: [runner] });
    const reloaded = { ...runner, routes: [{ id: "upload", method: "POST", path: "/upload" }] };
    stream.send([reloaded]);
    expect(received.at(-1)).toEqual({ status: "live", runners: [reloaded] });
    stream.dispatchEvent(new Event("error"));
    expect(received.at(-1)).toEqual({ status: "unavailable" });
    expect(stream.close).not.toHaveBeenCalled();
    stream.send([]);
    expect(received.at(-1)).toEqual({ status: "live", runners: [] });
  });

  it.each(["dispose", "abort"])("retries terminal HTTP failures and cancels pending retries on %s", (cleanup) => {
    const first = stream;
    first.send([runner]);
    first.readyState = 2;
    first.dispatchEvent(new Event("error"));
    expect(received.at(-1)).toEqual({ status: "unavailable" });
    expect(first.close).toHaveBeenCalledOnce();
    first.send([runner]);
    expect(received.at(-1)).toEqual({ status: "unavailable" });

    stream = new Events();
    vi.advanceTimersByTime(250);
    expect(open).toHaveBeenCalledTimes(2);
    expect(received.at(-1)).toEqual({ status: "unavailable" });
    stream.send([]);
    expect(received.at(-1)).toEqual({ status: "live", runners: [] });

    stream.readyState = 2;
    stream.dispatchEvent(new Event("error"));
    if (cleanup === "dispose") dispose();
    else abort.abort();
    vi.advanceTimersByTime(10_000);
    expect(open).toHaveBeenCalledTimes(2);
  });

  it("shows unavailable when no snapshot arrives, then recovers on a late snapshot", () => {
    vi.advanceTimersByTime(5_000);
    expect(received.at(-1)).toEqual({ status: "unavailable" });
    stream.send([runner]);
    expect(received.at(-1)).toEqual({ status: "live", runners: [runner] });
  });

  it("clears stale registrations if a snapshot cannot be parsed", () => {
    stream.send([runner]);
    stream.dispatchEvent(new MessageEvent("message", { data: "not-json" }));
    expect(received.at(-1)).toEqual({ status: "unavailable" });
    expect(stream.close).toHaveBeenCalledOnce();
  });
});
