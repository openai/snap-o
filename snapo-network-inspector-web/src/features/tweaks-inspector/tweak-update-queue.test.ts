import { describe, expect, it, vi } from "vitest";
import type { TweakUpdates } from "../../network/bridge-types";
import { TweakUpdateQueue } from "./tweak-update-queue";

describe("app-scoped tweak updates", () => {
  it("never sends a second app's pending edits to the first app", async () => {
    const firstRequest = deferred<TweakUpdates>();
    const secondRequest = deferred<TweakUpdates>();
    const client = {
      updateTweaks: vi.fn().mockReturnValueOnce(firstRequest.promise).mockReturnValueOnce(secondRequest.promise)
    };
    const firstCallbacks = callbacks();
    const secondCallbacks = callbacks();
    const firstServer = { deviceId: "pixel", socketName: "snapo_tweaks_first" };
    const secondServer = { deviceId: "pixel", socketName: "snapo_tweaks_second" };
    const firstQueue = new TweakUpdateQueue(client, firstServer, firstCallbacks);
    const secondQueue = new TweakUpdateQueue(client, secondServer, secondCallbacks);

    firstQueue.enqueue("Typography/Font size", 24);
    const firstFlush = firstQueue.flush();
    firstQueue.cancel();

    secondQueue.enqueue("Typography/Font size", 36);
    const secondFlush = secondQueue.flush();

    expect(client.updateTweaks).toHaveBeenNthCalledWith(1, {
      server: firstServer,
      values: { "Typography/Font size": 24 }
    });
    expect(client.updateTweaks).toHaveBeenNthCalledWith(2, {
      server: secondServer,
      values: { "Typography/Font size": 36 }
    });

    secondRequest.resolve({ tweaks: [{ name: "Typography/Font size", value: 36, modified: true }] });
    await secondFlush;

    firstRequest.resolve({ tweaks: [{ name: "Typography/Font size", value: 24, modified: true }] });
    await firstFlush;

    expect(client.updateTweaks).toHaveBeenCalledTimes(2);
    expect(firstCallbacks.onUpdate).not.toHaveBeenCalled();
    expect(secondCallbacks.onUpdate).toHaveBeenCalledOnce();
  });

  it("waits for the current request before sending coalesced slider updates", async () => {
    const firstRequest = deferred<TweakUpdates>();
    const secondRequest = deferred<TweakUpdates>();
    const client = {
      updateTweaks: vi.fn().mockReturnValueOnce(firstRequest.promise).mockReturnValueOnce(secondRequest.promise)
    };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const queue = new TweakUpdateQueue(client, server, callbacks());

    queue.enqueue("Motion/Duration", 400);
    const flush = queue.flush();
    queue.enqueue("Motion/Duration", 450);
    queue.enqueue("Motion/Duration", 500);
    void queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledTimes(1);

    firstRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 400, modified: true }] });
    await vi.waitFor(() => {
      expect(client.updateTweaks).toHaveBeenCalledTimes(2);
    });

    expect(client.updateTweaks).toHaveBeenNthCalledWith(2, {
      server,
      values: { "Motion/Duration": 500 }
    });

    secondRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 500, modified: true }] });
    await flush;
  });

  it("sends a null value to reset a tweak", async () => {
    const client = {
      updateTweaks: vi.fn().mockResolvedValue({
        tweaks: [{ name: "Motion/Duration", value: 300, modified: false }]
      })
    };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, server, handlers);

    queue.enqueue("Motion/Duration", null);
    await queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledWith({
      server,
      values: { "Motion/Duration": null }
    });
    expect(handlers.onUpdate).toHaveBeenCalledWith(
      [{ name: "Motion/Duration", value: 300, modified: false }],
      new Map()
    );
  });

  it("reports a rejected reset without leaving the request in flight", async () => {
    const client = { updateTweaks: vi.fn().mockRejectedValue(new Error("Invalid tweak value for Motion/Duration.")) };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, server, handlers);

    queue.enqueue("Motion/Duration", null);
    await expect(queue.flush()).resolves.toBeUndefined();

    expect(handlers.onError).toHaveBeenCalledWith("Invalid tweak value for Motion/Duration.");
    expect(queue.pending.size).toBe(0);
    expect(queue.inFlight.size).toBe(0);
    expect(handlers.onSavingChange).toHaveBeenLastCalledWith(false);
  });

  it("retries a rejected reset", async () => {
    const result = { tweaks: [{ name: "Motion/Duration", value: 300 }] };
    const client = {
      updateTweaks: vi.fn().mockRejectedValueOnce(new Error("Reset failed.")).mockResolvedValueOnce(result)
    };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, { deviceId: "pixel", socketName: "snapo_tweaks_demo" }, handlers);

    queue.enqueue("Motion/Duration", null);
    await queue.flush();
    queue.enqueue("Motion/Duration", null);
    await queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledTimes(2);
    expect(handlers.onUpdate).toHaveBeenCalledWith(result.tweaks, new Map());
  });

  it("lets a reset replace a queued value update", async () => {
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [] }) };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const queue = new TweakUpdateQueue(client, server, callbacks());

    queue.enqueue("Motion/Duration", 500);
    queue.enqueue("Motion/Duration", null);
    await queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledOnce();
    expect(client.updateTweaks).toHaveBeenCalledWith({ server, values: { "Motion/Duration": null } });
  });

  it("lets a new value replace a queued reset", async () => {
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [] }) };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const queue = new TweakUpdateQueue(client, server, callbacks());

    queue.enqueue("Motion/Duration", null);
    queue.enqueue("Motion/Duration", 500);
    await queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledOnce();
    expect(client.updateTweaks).toHaveBeenCalledWith({ server, values: { "Motion/Duration": 500 } });
  });

  it("waits for an in-flight value update before resetting it", async () => {
    const firstRequest = deferred<TweakUpdates>();
    const secondRequest = deferred<TweakUpdates>();
    const client = {
      updateTweaks: vi.fn().mockReturnValueOnce(firstRequest.promise).mockReturnValueOnce(secondRequest.promise)
    };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const queue = new TweakUpdateQueue(client, server, callbacks());

    queue.enqueue("Motion/Duration", 500);
    const flush = queue.flush();
    queue.enqueue("Motion/Duration", null);
    void queue.flush();

    firstRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 500, modified: true }] });
    await vi.waitFor(() => {
      expect(client.updateTweaks).toHaveBeenCalledTimes(2);
    });

    expect(client.updateTweaks).toHaveBeenNthCalledWith(2, { server, values: { "Motion/Duration": null } });
    secondRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 300, modified: false }] });
    await flush;
  });

  it("sends value changes and resets together", async () => {
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [] }) };
    const server = { deviceId: "pixel", socketName: "snapo_tweaks_demo" };
    const queue = new TweakUpdateQueue(client, server, callbacks());

    queue.enqueue("Motion/Duration", 500);
    queue.enqueue("Motion/Show", null);
    await queue.flush();

    expect(client.updateTweaks).toHaveBeenCalledOnce();
    expect(client.updateTweaks).toHaveBeenCalledWith({
      server,
      values: { "Motion/Duration": 500, "Motion/Show": null }
    });
  });

  it("applies successful values and reports each rejected value in the same batch", async () => {
    const first = { name: "Motion/Duration", error: "Value exceeds the maximum." };
    const second = { name: "Motion/Show", error: "Unknown tweak." };
    const update = { name: "Typography/Font size", value: 24 };
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [update], errors: [first, second] }) };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, { deviceId: "pixel", socketName: "snapo_tweaks_demo" }, handlers);

    queue.enqueue(update.name, update.value);
    queue.enqueue(first.name, 1_000);
    queue.enqueue(second.name, true);
    await queue.flush();

    expect(handlers.onUpdate).toHaveBeenCalledWith([update], new Map());
    expect(handlers.onRejected).toHaveBeenCalledWith([first, second], new Map(), new Set(), expect.any(Function));
    expect(handlers.onError).toHaveBeenLastCalledWith(
      "Motion/Duration: Value exceeds the maximum.; Motion/Show: Unknown tweak."
    );
    expect(queue.inFlight.size).toBe(0);
  });

  it("reports a batch with no successful values without leaving rejected values in flight", async () => {
    const error = { name: "Motion/Duration", error: "Invalid value." };
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [], errors: [error] }) };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, { deviceId: "pixel", socketName: "snapo_tweaks_demo" }, handlers);

    queue.enqueue(error.name, 900);
    await queue.flush();

    expect(handlers.onUpdate).toHaveBeenCalledWith([], new Map());
    expect(handlers.onRejected).toHaveBeenCalledOnce();
    expect(handlers.onError).toHaveBeenLastCalledWith("Motion/Duration: Invalid value.");
    expect(queue.pending.size).toBe(0);
    expect(queue.inFlight.size).toBe(0);
  });

  it("invalidates an authoritative reload when the selected app changes", async () => {
    const error = { name: "Motion/Duration", error: "Invalid value." };
    const client = { updateTweaks: vi.fn().mockResolvedValue({ tweaks: [], errors: [error] }) };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, { deviceId: "pixel", socketName: "snapo_tweaks_demo" }, handlers);

    queue.enqueue(error.name, 900);
    await queue.flush();
    const isCurrent = handlers.onRejected.mock.calls[0]?.[3] as () => boolean;

    expect(isCurrent()).toBe(true);
    queue.cancel();
    expect(isCurrent()).toBe(false);
  });

  it("does not report an old app's request failure after switching apps", async () => {
    const request = deferred<TweakUpdates>();
    const client = { updateTweaks: vi.fn().mockReturnValue(request.promise) };
    const handlers = callbacks();
    const queue = new TweakUpdateQueue(client, { deviceId: "pixel", socketName: "snapo_tweaks_first" }, handlers);

    queue.enqueue("Motion/Duration", 400);
    const flush = queue.flush();
    queue.cancel();
    request.reject(new Error("The previous app disconnected."));
    await flush;

    expect(handlers.onError).not.toHaveBeenCalled();
    expect(handlers.onUpdate).not.toHaveBeenCalled();
  });
});

function callbacks() {
  return {
    onUpdate: vi.fn(),
    onRejected: vi.fn(),
    onError: vi.fn(),
    onSavingChange: vi.fn()
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((complete, fail) => {
    resolve = complete;
    reject = fail;
  });

  return { promise, resolve, reject };
}
