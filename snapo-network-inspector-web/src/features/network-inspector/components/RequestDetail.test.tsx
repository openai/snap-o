import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { NetworkClient } from "../../../network/client";
import type { RequestRecord } from "../../../network/cdp";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { RequestDetail } from "./RequestDetail";

describe("Response Body loading state", () => {
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
