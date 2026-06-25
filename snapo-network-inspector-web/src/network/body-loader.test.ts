import { describe, expect, it } from "vitest";
import { bodyLoadPriority, RequestBodyLoader, type BodyLoadJob } from "./body-loader";
import type { RequestBodies } from "./bridge-types";

describe("RequestBodyLoader", () => {
  it("limits concurrency and starts selected and visible requests first", async () => {
    const started: string[] = [];
    const loaded: string[] = [];
    const pending = new Map<string, ReturnType<typeof deferred<RequestBodies>>>();
    const loader = new RequestBodyLoader(
      (input) => {
        started.push(input.requestId);
        const result = deferred<RequestBodies>();
        pending.set(input.requestId, result);
        return result.promise;
      },
      (recordKey) => loaded.push(recordKey),
      2
    );
    const jobs = [
      job("background-1", bodyLoadPriority.background),
      job("background-2", bodyLoadPriority.background),
      job("visible", bodyLoadPriority.visible),
      job("selected", bodyLoadPriority.selected)
    ];

    loader.retainRecords(new Set(jobs.map((item) => item.recordKey)));
    loader.schedule(jobs);
    expect(started).toEqual(["selected", "visible"]);

    pending.get("selected")?.resolve({ requestId: "selected", requestBody: "body" });
    await nextTask();
    expect(started).toEqual(["selected", "visible", "background-1"]);
    expect(loaded).toEqual(["selected"]);

    loader.dispose();
  });

  it("allows an evicted record to be loaded again", async () => {
    const loaded: string[] = [];
    const loader = new RequestBodyLoader(
      async (input) => ({ requestId: input.requestId, responseBody: input.requestId }),
      (recordKey) => loaded.push(recordKey),
      1
    );
    const request = job("request", bodyLoadPriority.selected);
    loader.retainRecords(new Set([request.recordKey]));

    loader.schedule([request]);
    await nextTask();
    loader.forgetRecords([request.recordKey]);
    loader.schedule([request]);
    await nextTask();

    expect(loaded).toEqual(["request", "request"]);
    loader.dispose();
  });

  it("ignores an evicted in-flight result and allows its replacement to load", async () => {
    const pending: Array<ReturnType<typeof deferred<RequestBodies>>> = [];
    const loaded: string[] = [];
    const loader = new RequestBodyLoader(
      () => {
        const result = deferred<RequestBodies>();
        pending.push(result);
        return result.promise;
      },
      (_recordKey, bodies) => loaded.push(bodies.responseBody ?? "missing"),
      1
    );
    const request = job("request", bodyLoadPriority.selected);
    loader.retainRecords(new Set([request.recordKey]));

    loader.schedule([request]);
    loader.forgetRecords([request.recordKey]);
    loader.schedule([request]);
    expect(pending).toHaveLength(1);

    pending[0].resolve({ requestId: "request", responseBody: "stale" });
    await nextTask();
    expect(loaded).toEqual([]);
    expect(pending).toHaveLength(2);

    pending[1].resolve({ requestId: "request", responseBody: "fresh" });
    await nextTask();
    expect(loaded).toEqual(["fresh"]);
    loader.dispose();
  });
});

function job(requestId: string, priority: BodyLoadJob["priority"]): BodyLoadJob {
  return {
    key: `${requestId}:request`,
    recordKey: requestId,
    priority,
    input: {
      deviceId: "device",
      socketName: "socket",
      requestId,
      includeRequestBody: true
    }
  };
}

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolvePromise: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    resolvePromise = resolve;
  });
  return { promise, resolve: resolvePromise };
}

function nextTask(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
