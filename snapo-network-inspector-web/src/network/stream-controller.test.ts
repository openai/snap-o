import { afterEach, describe, expect, it, vi } from "vitest";
import type { StartStreamInput, StreamStarted, StreamStatus } from "./bridge-types";
import { NetworkStreamController, type StreamLifecycleState } from "./stream-controller";

describe("NetworkStreamController", () => {
  afterEach(() => vi.useRealTimers());

  it("retries failed starts with capped backoff", async () => {
    vi.useFakeTimers();
    const client = new TestStreamClient();
    client.startResults.push(new Error("first"), new Error("second"), { streamId: "stream-3" });
    const states: StreamLifecycleState[] = [];
    const controller = new NetworkStreamController(client, server, (state) => states.push(state));

    controller.start();
    await settlePromises();
    expect(client.startCount).toBe(1);
    expect(states).toEqual(["starting", "retrying"]);

    await vi.advanceTimersByTimeAsync(249);
    expect(client.startCount).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(client.startCount).toBe(2);
    await vi.advanceTimersByTimeAsync(499);
    expect(client.startCount).toBe(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(client.startCount).toBe(3);
    expect(states.at(-1)).toBe("streaming");

    controller.dispose();
    expect(client.stopped).toEqual(["stream-3"]);
  });

  it("retries when an active stream exits", async () => {
    vi.useFakeTimers();
    const client = new TestStreamClient();
    client.startResults.push({ streamId: "stream-1" }, { streamId: "stream-2" });
    const controller = new NetworkStreamController(client, server, () => {});

    controller.start();
    await settlePromises();
    client.emitStatus({ streamId: "stream-1", state: "exit" });
    await vi.advanceTimersByTimeAsync(250);

    expect(client.startCount).toBe(2);
    controller.dispose();
    expect(client.stopped).toEqual(["stream-2"]);
  });

  it("handles a terminal status emitted before start resolves", async () => {
    vi.useFakeTimers();
    const client = new TestStreamClient();
    const pending = deferred<StreamStarted>();
    client.startResults.push(pending.promise, { streamId: "stream-2" });
    const controller = new NetworkStreamController(client, server, () => {});

    controller.start();
    client.emitStatus({ streamId: "stream-1", state: "error", message: "closed" });
    pending.resolve({ streamId: "stream-1" });
    await settlePromises();
    await vi.advanceTimersByTimeAsync(250);

    expect(client.startCount).toBe(2);
    controller.dispose();
  });

  it("cancels a scheduled retry when disposed", async () => {
    vi.useFakeTimers();
    const client = new TestStreamClient();
    client.startResults.push(new Error("unavailable"));
    const controller = new NetworkStreamController(client, server, () => {});

    controller.start();
    await settlePromises();
    controller.dispose();
    await vi.runAllTimersAsync();

    expect(client.startCount).toBe(1);
    expect(client.hasStatusListener).toBe(false);
  });

  it("caps repeated retry delays", async () => {
    vi.useFakeTimers();
    const client = new TestStreamClient();
    client.startResults.push(new Error("first"), new Error("second"), new Error("third"), { streamId: "stream-4" });
    const controller = new NetworkStreamController(client, server, () => {}, { retryDelaysMs: [10, 20] });

    controller.start();
    await settlePromises();
    await vi.advanceTimersByTimeAsync(10);
    await vi.advanceTimersByTimeAsync(20);
    await vi.advanceTimersByTimeAsync(19);
    expect(client.startCount).toBe(3);
    await vi.advanceTimersByTimeAsync(1);

    expect(client.startCount).toBe(4);
    controller.dispose();
  });
});

const server: StartStreamInput = { deviceId: "device", socketName: "socket" };

class TestStreamClient {
  readonly startResults: Array<StreamStarted | Error | Promise<StreamStarted>> = [];
  readonly stopped: string[] = [];
  private statusCallback: ((status: StreamStatus) => void) | null = null;
  startCount = 0;

  get hasStatusListener(): boolean {
    return this.statusCallback != null;
  }

  startStream(): Promise<StreamStarted> {
    this.startCount += 1;
    const result = this.startResults.shift();
    if (result instanceof Error) return Promise.reject(result);
    return Promise.resolve(result ?? { streamId: `stream-${this.startCount}` });
  }

  async stopStream(streamId: string): Promise<void> {
    this.stopped.push(streamId);
  }

  onStatus(callback: (status: StreamStatus) => void): () => void {
    this.statusCallback = callback;
    return () => {
      this.statusCallback = null;
    };
  }

  emitStatus(status: StreamStatus): void {
    this.statusCallback?.(status);
  }
}

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolvePromise: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    resolvePromise = resolve;
  });
  return { promise, resolve: resolvePromise };
}

async function settlePromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}
