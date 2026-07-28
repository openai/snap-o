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

    secondRequest.resolve({ tweaks: [{ name: "Typography/Font size", value: 36 }] });
    await secondFlush;

    firstRequest.resolve({ tweaks: [{ name: "Typography/Font size", value: 24 }] });
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

    firstRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 400 }] });
    await vi.waitFor(() => {
      expect(client.updateTweaks).toHaveBeenCalledTimes(2);
    });

    expect(client.updateTweaks).toHaveBeenNthCalledWith(2, {
      server,
      values: { "Motion/Duration": 500 }
    });

    secondRequest.resolve({ tweaks: [{ name: "Motion/Duration", value: 500 }] });
    await flush;
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
