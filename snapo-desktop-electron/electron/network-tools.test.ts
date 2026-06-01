import assert from "node:assert/strict";
import test from "node:test";
import { NetworkEventFilter } from "./network-event-filter.js";
import { sanitizeCdpMessage, sanitizeStringHeaders } from "../src/network/sanitization.js";
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

test("sanitizeCdpMessage redacts sensitive header values by default", () => {
  const message = {
    method: "Network.requestWillBeSent",
    params: {
      request: {
        headers: {
          Authorization: "Bearer secret",
          Cookie: "session=secret",
          Accept: "application/json"
        }
      }
    }
  };

  assert.deepEqual(sanitizeCdpMessage(message, "redact"), {
    method: "Network.requestWillBeSent",
    params: {
      request: {
        headers: {
          Authorization: "[REDACTED]",
          Cookie: "[REDACTED]",
          Accept: "application/json"
        }
      }
    }
  });
  assert.equal(message.params.request.headers.Authorization, "Bearer secret");
});

test("sanitizeCdpMessage drops the sensitive headers omitted by HAR export", () => {
  assert.deepEqual(
    sanitizeCdpMessage(
      {
        method: "Network.responseReceived",
        params: {
          response: {
            headers: {
              "Set-Cookie": "session=secret",
              "Content-Type": "application/json"
            }
          }
        }
      },
      "drop"
    ),
    {
      method: "Network.responseReceived",
      params: {
        response: {
          headers: {
            "Content-Type": "application/json"
          }
        }
      }
    }
  );
});

test("sanitizeStringHeaders applies the same case-insensitive header policy", () => {
  assert.deepEqual(
    sanitizeStringHeaders(
      {
        authorization: "Bearer secret",
        COOKIE: "session=secret",
        Accept: "application/json"
      },
      "request",
      "drop"
    ),
    {
      Accept: "application/json"
    }
  );
});
