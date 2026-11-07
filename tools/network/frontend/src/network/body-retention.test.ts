import { describe, expect, it } from "vitest";
import { RequestBodyCache } from "./body-retention";

describe("RequestBodyCache", () => {
  it("counts and evicts original bodies with the delivered body without mixing app processes", () => {
    const cache = new RequestBodyCache(32);
    const oldProcess = "process-1\u0000request";
    const newProcess = "process-2\u0000request";
    cache.select(oldProcess);
    cache.put(oldProcess, { requestId: "request", responseBody: "1234" });
    cache.put(oldProcess, {
      requestId: "request",
      originalResponseBody: "original",
      originalResponseBodyLoadCompleted: true
    });
    expect(cache.retainedByteCount).toBe(24);
    cache.select(newProcess);
    expect(cache.put(newProcess, { requestId: "request", responseBody: "fresh" })).toEqual([oldProcess]);
    expect(cache.peek(oldProcess)).toBeNull();
    expect(cache.peek(newProcess)?.responseBody).toBe("fresh");
    expect(cache.peek(newProcess)?.originalResponseBody).toBeUndefined();
    expect(cache.retainedByteCount).toBe(10);
  });

  it("evicts least-recently-used bodies when the byte budget is exceeded", () => {
    const cache = new RequestBodyCache(20);

    cache.put("a", { requestId: "a", responseBody: "123456" });
    const evicted = cache.put("b", { requestId: "b", responseBody: "abcdef" });

    expect(cache.peek("a")).toBeNull();
    expect(cache.peek("b")?.responseBody).toBe("abcdef");
    expect(cache.retainedByteCount).toBe(12);
    expect(evicted).toEqual(["a"]);
  });

  it("keeps the selected record even when it exceeds the normal budget", () => {
    const cache = new RequestBodyCache(10);
    cache.select("selected");

    cache.put("selected", { requestId: "selected", responseBody: "oversized" });
    cache.put("other", { requestId: "other", responseBody: "body" });

    expect(cache.peek("selected")?.responseBody).toBe("oversized");
    expect(cache.peek("other")).toBeNull();

    cache.select(null);
    expect(cache.peek("selected")).toBeNull();
    expect(cache.retainedByteCount).toBe(0);
  });

  it("merges independently loaded request and response bodies", () => {
    const cache = new RequestBodyCache(100);

    cache.put("request", { requestId: "request", requestBody: "input" });
    cache.put("request", {
      requestId: "request",
      responseBody: "output",
      responseBodyBase64Encoded: false,
      responseBodyLoadCompleted: true
    });

    expect(cache.peek("request")).toEqual({
      requestId: "request",
      requestBody: "input",
      responseBody: "output",
      responseBodyBase64Encoded: false,
      responseBodyLoadCompleted: true
    });
  });

  it("drops bodies for records no longer retained by the tool", () => {
    const cache = new RequestBodyCache(100);
    cache.put("a", { requestId: "a", requestBody: "a" });
    cache.put("b", { requestId: "b", requestBody: "b" });

    const evicted = cache.retainRecords(new Set(["b"]));

    expect(cache.peek("a")).toBeNull();
    expect(cache.peek("b")?.requestBody).toBe("b");
    expect(evicted).toEqual(["a"]);
  });

  it("clears a response failure for retry without losing the request body", () => {
    const cache = new RequestBodyCache(100);
    cache.put("request", {
      requestId: "request",
      requestBody: "input",
      responseBodyLoadCompleted: true,
      responseBodyLoadError: "failed"
    });
    cache.put("request", { requestId: "request", requestBody: "input" });
    expect(cache.peek("request")?.responseBodyLoadError).toBe("failed");
    cache.put("request", {
      requestId: "request",
      responseBodyLoadCompleted: false,
      responseBodyLoadError: null
    });
    expect(cache.peek("request")).toMatchObject({
      requestBody: "input",
      responseBodyLoadCompleted: false,
      responseBodyLoadError: null
    });
  });
});
