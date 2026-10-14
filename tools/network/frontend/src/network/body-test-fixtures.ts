import type { BodySearchMatch, RequestBodySearchMatch } from "./remote-body-search";
import type { RequestRecord } from "./cdp";

export function request(processId = "current", overrides: Partial<RequestRecord> = {}): RequestRecord {
  return {
    kind: "request",
    processId,
    requestId: "same-id",
    method: "POST",
    url: "https://example.test/orders",
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "success", code: 200 },
    startedAt: 1,
    endedAt: 2,
    updatedAt: 2,
    streamEvents: [],
    streamEventCount: 0,
    requestHasPostData: false,
    ...overrides
  };
}

export function bodyMatch(requestId = "same-id", response: Partial<BodySearchMatch> = {}): RequestBodySearchMatch {
  return {
    requestId,
    request: { terms: [], complete: true },
    response: { terms: ["needle"], complete: true, ...response }
  };
}
