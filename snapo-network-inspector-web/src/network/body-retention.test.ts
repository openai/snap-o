import { describe, expect, it } from "vitest";
import { RequestBodyCache } from "./body-retention";

describe("RequestBodyCache", () => {
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
      responseBodyBase64Encoded: false
    });

    expect(cache.peek("request")).toEqual({
      requestId: "request",
      requestBody: "input",
      responseBody: "output",
      responseBodyBase64Encoded: false
    });
  });

  it("drops bodies for records no longer retained by the inspector", () => {
    const cache = new RequestBodyCache(100);
    cache.put("a", { requestId: "a", requestBody: "a" });
    cache.put("b", { requestId: "b", requestBody: "b" });

    const evicted = cache.retainRecords(new Set(["b"]));

    expect(cache.peek("a")).toBeNull();
    expect(cache.peek("b")?.requestBody).toBe("b");
    expect(evicted).toEqual(["a"]);
  });
});
