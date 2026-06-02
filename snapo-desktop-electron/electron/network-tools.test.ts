import assert from "node:assert/strict";
import test from "node:test";
import { NetworkEventFilter } from "./network-event-filter.js";
import { isLikelyStreamingRequest } from "../src/network/request-classification.js";
import { matchesUrlFilterText } from "../src/network/url-filter.js";

test("matchesUrlFilterText uses the Network Inspector search syntax", () => {
  assert.equal(matchesUrlFilterText("https://example.invalid/backend-api/models", "backend-api"), true);
  assert.equal(matchesUrlFilterText("https://example.invalid/backend-api/sentinel", "backend-api -sentinel"), false);
  assert.equal(matchesUrlFilterText("https://example.invalid/backend api/models", '"backend api"'), true);
  assert.equal(matchesUrlFilterText("https://example.invalid/backend api/models", "backend\\ api"), true);
});

test("NetworkEventFilter keeps lifecycle events for matched request IDs", () => {
  const filter = new NetworkEventFilter("backend-api -sentinel");

  assert.equal(
    filter.matches({
      method: "Network.requestWillBeSent",
      params: {
        requestId: "models",
        request: { url: "https://example.invalid/backend-api/models" }
      }
    }),
    true
  );
  assert.equal(filter.matches({ method: "Network.loadingFinished", params: { requestId: "models" } }), true);
  assert.equal(
    filter.matches({
      method: "Network.requestWillBeSent",
      params: {
        requestId: "sentinel",
        request: { url: "https://example.invalid/backend-api/sentinel" }
      }
    }),
    false
  );
  assert.equal(filter.matches({ method: "Network.loadingFinished", params: { requestId: "sentinel" } }), false);
});

test("observed non-SSE responses override request-side SSE hints", () => {
  const hintedRequest = {
    requestHeaders: [{ name: "Accept", value: "text/event-stream,application/json" }],
    responseHeaders: [],
    streamEvents: []
  };

  assert.equal(isLikelyStreamingRequest(hintedRequest), true);
  assert.equal(
    isLikelyStreamingRequest({
      ...hintedRequest,
      responseHeaders: [{ name: "Content-Type", value: "application/json" }],
      responseType: "XHR",
      hasReceivedResponse: true
    }),
    false
  );
  assert.equal(
    isLikelyStreamingRequest({
      ...hintedRequest,
      responseHeaders: [{ name: "Content-Type", value: "text/event-stream" }],
      responseType: "EventSource",
      hasReceivedResponse: true
    }),
    true
  );
});
