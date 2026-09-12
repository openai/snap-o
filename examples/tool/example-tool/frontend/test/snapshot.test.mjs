import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { observeExample } from "../.test-build/snapshot.js";

class FakeHost extends EventTarget {
  connection = {
    baseURL: "http://127.0.0.1:12345/",
    protocolVersion: 1,
    processIdentity: "boot:42:1",
    signal: new AbortController().signal,
  };
  onConnection(callback) {
    this.addEventListener("connection", callback);
    callback();
    return () => this.removeEventListener("connection", callback);
  }
}

const sample = (revision = 0) => ({
  protocolVersion: 1,
  revision,
  items: [{ id: "fake-1", name: "Fake counter", value: revision }],
});
const streams = [];
const originalEventSource = globalThis.EventSource;
class FakeEventSource extends EventTarget {
  closed = false;
  constructor(url) {
    super();
    this.url = url;
    streams.push(this);
  }
  close() {
    this.closed = true;
  }
  snapshot(payload) {
    this.dispatchEvent(
      new MessageEvent("snapshot", { data: JSON.stringify(payload) }),
    );
  }
}
beforeEach(() => {
  globalThis.EventSource = FakeEventSource;
});
afterEach(() => {
  mock.restoreAll();
  streams.length = 0;
  globalThis.EventSource = originalEventSource;
});

test("inactive pages abort pending work and close their event stream", async () => {
  let complete;
  const fetch = mock.method(
    globalThis,
    "fetch",
    () =>
      new Promise((resolve) => {
        complete = resolve;
      }),
  );
  const host = new FakeHost();
  let state;
  const observer = observeExample(host, (next) => {
    state = next;
  });
  const signal = fetch.mock.calls[0].arguments[1].signal;
  assert.equal(streams.length, 1);
  host.connection = null;
  host.dispatchEvent(new Event("connection"));
  assert.equal(signal.aborted, true);
  assert.equal(streams[0].closed, true);
  complete(new Response(JSON.stringify(sample())));
  streams[0].snapshot(sample(2));
  await setImmediate();
  assert.deepEqual(state, {
    connected: false,
    items: [],
    message: "Disconnected",
  });
  observer.dispose();
});

test("activation resumes requests and disposal removes the listener", async () => {
  const fetch = mock.method(
    globalThis,
    "fetch",
    async () => new Response(JSON.stringify(sample())),
  );
  const host = new FakeHost();
  host.connection = null;
  let state;
  const observer = observeExample(host, (next) => {
    state = next;
  });
  assert.equal(fetch.mock.calls.length, 0);
  host.connection = {
    baseURL: "http://127.0.0.1:12345/",
    protocolVersion: 1,
    processIdentity: "boot:42:2",
    signal: new AbortController().signal,
  };
  host.dispatchEvent(new Event("connection"));
  await setImmediate();
  assert.deepEqual(state.items, sample().items);
  observer.dispose();
  host.dispatchEvent(new Event("connection"));
  assert.equal(streams[0].closed, true);
  assert.equal(streams.length, 1);
  assert.equal(fetch.mock.calls.length, 1);
});

test("the tool validates its own protocol before making requests", () => {
  const fetch = mock.method(globalThis, "fetch", async () => new Response());
  const host = new FakeHost();
  host.connection.protocolVersion = 2;
  let state;
  const observer = observeExample(host, (next) => {
    state = next;
  });
  assert.equal(fetch.mock.calls.length, 0);
  assert.equal(streams.length, 0);
  assert.match(state.message, /requires protocol 1/);
  observer.dispose();
});

test("fake mutation uses POST and applies its snapshot", async () => {
  const fetch = mock.method(
    globalThis,
    "fetch",
    async (_url, options) =>
      new Response(JSON.stringify(sample(options.method === "POST" ? 1 : 0))),
  );
  let state;
  const observer = observeExample(new FakeHost(), (next) => {
    state = next;
  });
  await setImmediate();
  await observer.increment();
  assert.equal(fetch.mock.calls[1].arguments[0].pathname, "/example/increment");
  assert.equal(fetch.mock.calls[1].arguments[1].method, "POST");
  assert.equal(state.items[0].value, 1);
  observer.dispose();
});

test("an older GET cannot overwrite a newer SSE snapshot", async () => {
  let complete;
  mock.method(
    globalThis,
    "fetch",
    () =>
      new Promise((resolve) => {
        complete = resolve;
      }),
  );
  let state;
  const observer = observeExample(new FakeHost(), (next) => {
    state = next;
  });
  assert.equal(streams[0].url.pathname, "/example/events");
  streams[0].snapshot(sample(1));
  complete(new Response(JSON.stringify(sample(0))));
  await setImmediate();
  assert.equal(state.items[0].value, 1);
  streams[0].snapshot({ invalid: true });
  assert.match(state.message, /Unsupported Example snapshot/);
  observer.dispose();
});

test("disconnect aborts an in-flight mutation and suppresses its late result", async () => {
  let complete;
  const fetch = mock.method(globalThis, "fetch", async (_url, options) => {
    if (options.method === "GET") return new Response(JSON.stringify(sample()));
    return new Promise((resolve) => {
      complete = resolve;
    });
  });
  const host = new FakeHost();
  let state;
  const observer = observeExample(host, (next) => {
    state = next;
  });
  await setImmediate();
  const command = observer.increment();
  host.connection = null;
  host.dispatchEvent(new Event("connection"));
  assert.equal(fetch.mock.calls[1].arguments[1].signal.aborted, true);
  complete(new Response(JSON.stringify(sample(1))));
  await command;
  assert.deepEqual(state, {
    connected: false,
    items: [],
    message: "Disconnected",
  });
  observer.dispose();
});
