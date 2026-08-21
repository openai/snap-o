import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestRecord } from "../../../network/cdp";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { RequestDetail } from "./RequestDetail";

describe("Response Body loading state", () => {
  it("shows an uncached body as offline instead of loading forever", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ encodedDataLength: 12 })}
        uiState={expandedUiState}
        isConnected={false}
        onRetryResponseBody={() => {}}
      />
    );
    expect(markup).toContain("Response body isn’t cached on this Mac.");
    expect(markup).not.toContain("body-loading-spinner");
    expect(markup).not.toContain(">Retry</button>");
  });

  it("keeps a cached body readable offline", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ responseBody: "cached-response" })}
        uiState={expandedUiState}
        isConnected={false}
        onRetryResponseBody={() => {}}
      />
    );
    expect(markup).toContain("cached-response");
    expect(markup).not.toContain("isn’t cached");
  });
  it("shows the captured size and an accessible loading indicator before hydration completes", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ encodedDataLength: 7_340_032 })}
        uiState={expandedUiState}
        onRetryResponseBody={() => {}}
      />
    );

    expect(markup).toContain("Response Body");
    expect(markup).toContain("Captured 7.3 MB");
    expect(markup).toContain('<div class="payload-card"><div class="body-loading" role="status">');
    expect(markup).toContain("body-loading-spinner");
    expect(markup).toContain('aria-hidden="true"');
    expect(markup).toContain("Loading...");
  });

  it("shows the captured prefix and total size while a truncated body is loading", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ encodedDataLength: 9_437_184, responseBodyTruncatedBytes: 4_194_304 })}
        uiState={expandedUiState}
        onRetryResponseBody={() => {}}
      />
    );

    expect(markup).toContain("Response Body");
    expect(markup).toContain("Captured 5.2 MB of 9.4 MB");
    expect(markup).toContain("Loading...");
  });

  it("explains when a body is no longer available", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({
          encodedDataLength: 7_340_032,
          responseBodyLoadCompleted: true,
          responseBodyLoadError: "unavailable"
        })}
        uiState={expandedUiState}
        onRetryResponseBody={() => {}}
      />
    );

    expect(markup).toContain("Response Body");
    expect(markup).toContain("This response is no longer available. Try making the request again.");
    expect(markup).not.toContain("Captured 7.3 MB");
    expect(markup).not.toContain("Retry");
    expect(markup).not.toContain("Loading...");
  });

  it("offers a retry after a temporary failure", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ responseBodyLoadCompleted: true, responseBodyLoadError: "failed" })}
        uiState={expandedUiState}
        onRetryResponseBody={() => {}}
      />
    );
    expect(markup).toContain("Couldn’t load the response. Try again.");
    expect(markup).toContain('type="button">Retry</button>');
    expect(markup).not.toContain("no longer available");
    expect(markup).not.toContain("Loading...");
  });

  it("does not label a genuinely empty response as unavailable", () => {
    const markup = renderToStaticMarkup(
      <RequestDetail
        client={{} as NetworkClient}
        record={request({ status: { kind: "success", code: 204 }, encodedDataLength: 0 })}
        uiState={expandedUiState}
        onRetryResponseBody={() => {}}
      />
    );
    expect(markup).not.toContain("Response Body");
    expect(markup).not.toContain("no longer available");
  });
});

describe("SSE stream status", () => {
  it("shows a closed status without a completion footer or totals", () => {
    const markup = renderStream({
      streamClosed: { timestamp: 2, reason: "completed", totalEvents: 1, totalBytes: 128 }
    });

    expect(markup).toContain("· Closed");
    expect(markup).toContain("sample-event");
    expect(markup).not.toContain("Stream closed");
    expect(markup).not.toContain("Total events");
    expect(markup).not.toContain("Total bytes");
  });

  it.each([false, undefined])(
    "keeps the SSE handshake pending when hasReceivedResponse is %s",
    (hasReceivedResponse) => {
      const markup = renderStream({
        requestHeaders: [{ name: "Accept", value: "text/event-stream" }],
        responseHeaders: [],
        hasReceivedResponse,
        status: { kind: "pending" },
        streamEvents: [],
        streamEventCount: 0
      });

      expect(markup).toContain("· Pending");
      expect(markup).toContain("Waiting for response...");
      expect(markup).not.toContain("· Streaming");
    }
  );

  it("shows streaming after the response arrives, before the first event", () => {
    const markup = renderStream({ streamEvents: [], streamEventCount: 0 });

    expect(markup).toContain("· Streaming");
    expect(markup).toContain("Awaiting events...");
    expect(markup).not.toContain("Waiting for response...");
    expect(markup).not.toContain("Stream closed");
  });

  it("treats a received event as response evidence when response metadata is missing", () => {
    const markup = renderStream({
      responseHeaders: [],
      hasReceivedResponse: undefined,
      status: { kind: "pending" }
    });

    expect(markup).toContain("· Streaming");
    expect(markup).not.toContain("Waiting for response...");
  });

  it("keeps a failed handshake closed even without a response", () => {
    const markup = renderStream({
      requestHeaders: [{ name: "Accept", value: "text/event-stream" }],
      responseHeaders: [],
      hasReceivedResponse: false,
      status: { kind: "failure", message: "Connection refused." },
      streamEvents: [],
      streamEventCount: 0,
      streamClosed: { timestamp: 2, reason: "error", message: "Connection refused." }
    });

    expect(markup).toContain("· Closed");
    expect(markup).toContain("Stream closed: Connection refused.");
    expect(markup).not.toContain("· Pending");
    expect(markup).not.toContain("· Streaming");
  });

  it("does not keep waiting after an empty stream closes", () => {
    const markup = renderStream({
      streamEvents: [],
      streamEventCount: 0,
      streamClosed: { timestamp: 2, reason: "completed" }
    });

    expect(markup).toContain("· Closed");
    expect(markup).toContain("No events received.");
    expect(markup).not.toContain("Awaiting events");
  });

  it("shows a stream failure once, below the retained events", () => {
    const markup = renderStream({
      status: { kind: "failure", message: "Read timed out." },
      streamClosed: { timestamp: 2, reason: "error", message: "Read timed out." }
    });

    expect(markup).toContain("· Closed");
    expect(markup).toContain('role="status">Stream closed: Read timed out.</div>');
    expect(markup.match(/Read timed out\./g)).toHaveLength(1);
    expect(markup.indexOf("Stream closed:")).toBeGreaterThan(markup.indexOf("sample-event"));
  });

  it.each([
    { reason: "error", message: undefined, expected: "Connection error." },
    { reason: "error", message: "  ", expected: "Connection error." },
    { reason: "cancelled", message: undefined, expected: "cancelled" }
  ])("keeps an abnormal close reason when its message is $message", ({ reason, message, expected }) => {
    const markup = renderStream({ streamClosed: { timestamp: 2, reason, message } });

    expect(markup).toContain(`Stream closed: ${expected}`);
  });

  it.each([false, true])(
    "shows a consistent offline state when hasReceivedResponse is %s",
    (hasReceivedResponse) => {
      const markup = renderStream(
        {
          requestHeaders: [{ name: "Accept", value: "text/event-stream" }],
          responseHeaders: hasReceivedResponse ? [{ name: "Content-Type", value: "text/event-stream" }] : [],
          hasReceivedResponse,
          status: hasReceivedResponse ? { kind: "success", code: 200 } : { kind: "pending" },
          streamEvents: [],
          streamEventCount: 0
        },
        false
      );

      expect(markup).toContain("· Offline");
      expect(markup).toContain("No events received.");
      expect(markup).not.toContain("· Streaming");
      expect(markup).not.toContain("· Closed");
      expect(markup).not.toContain("Awaiting events");
      expect(markup).not.toContain("Waiting for response...");
    }
  );
});

function renderStream(overrides: Partial<RequestRecord>, isConnected = true): string {
  return renderToStaticMarkup(
    <RequestDetail
      client={{} as NetworkClient}
      record={request({
        endedAt: undefined,
        hasReceivedResponse: true,
        responseHeaders: [{ name: "Content-Type", value: "text/event-stream" }],
        streamEvents: [{ sequence: 1, timestamp: 1, data: "sample-event", raw: "data: sample-event\n\n" }],
        streamEventCount: 1,
        ...overrides
      })}
      uiState={expandedUiState}
      isConnected={isConnected}
      onRetryResponseBody={() => {}}
    />
  );
}

const expandedUiState: InspectorUiState = {
  sectionExpanded: () => true,
  setSectionExpanded: () => {},
  prettyEnabled: (_key, fallback) => fallback,
  setPrettyEnabled: () => {},
  jsonExpanded: (_key, fallback) => fallback,
  setJsonExpanded: () => {}
};

function request(overrides: Partial<RequestRecord>): RequestRecord {
  return {
    kind: "request",
    server: { deviceId: "device", socketName: "socket", instanceId: "instance" },
    requestId: "request",
    method: "GET",
    url: "https://example.com/large-response",
    requestHeaders: [],
    responseHeaders: [{ name: "Content-Type", value: "application/json" }],
    status: { kind: "success", code: 200 },
    startedAt: 1,
    endedAt: 2,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 2,
    ...overrides
  };
}
