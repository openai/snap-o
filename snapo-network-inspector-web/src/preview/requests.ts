import type { RequestRecord } from "../network/cdp";

const startedAt = Date.parse("2026-08-21T12:00:00Z");

function request(requestId: string, overrides: Partial<RequestRecord> = {}): RequestRecord {
  const record: RequestRecord = {
    kind: "request",
    server: { deviceId: "preview-device", socketName: "preview-socket" },
    requestId,
    method: "POST",
    url: "https://api.example.com/v1/orders?include=items,shipping&locale=en-US",
    requestHeaders: [
      { name: "Content-Type", value: "application/json; charset=utf-8" },
      { name: "Accept", value: "application/json" },
      { name: "User-Agent", value: "ExampleApp/1.0 (Android)" },
      { name: "X-Request-ID", value: "preview-request-001" }
    ],
    requestBody: JSON.stringify({
      items: [
        { product_id: "notebook-01", quantity: 2 },
        { product_id: "pencil-02", quantity: 3 }
      ],
      shipping: { method: "standard", city: "Example City", country: "US" },
      coupon: null
    }),
    responseHeaders: [
      { name: "Content-Type", value: "application/json; charset=utf-8" },
      { name: "Cache-Control", value: "no-store" },
      { name: "Date", value: "Fri, 21 Aug 2026 12:00:00 GMT" },
      { name: "X-Request-ID", value: "preview-request-001" },
      { name: "Server-Timing", value: "db;dur=38, app;dur=94" },
      { name: "Vary", value: "Accept-Encoding, Accept-Language" }
    ],
    responseBody: JSON.stringify({
      id: "order-1042",
      status: "confirmed",
      currency: "USD",
      total: 31.5,
      items: [
        { product_id: "notebook-01", name: "Grid notebook", quantity: 2, unit_price: 12 },
        { product_id: "pencil-02", name: "Drawing pencil", quantity: 3, unit_price: 2.5 }
      ],
      shipping: { method: "standard", estimated_days: 4, tracking_url: null },
      metadata: { source: "android", gift: false, tags: ["stationery", "back-to-school"] }
    }),
    responseBodyLoadCompleted: true,
    hasReceivedResponse: true,
    status: { kind: "success", code: 201 },
    startedAt,
    endedAt: startedAt + 248,
    updatedAt: startedAt + 248,
    streamEvents: [],
    streamEventCount: 0,
    ...overrides
  };
  record.encodedDataLength = new TextEncoder().encode(record.responseBody ?? "").byteLength;
  return record;
}

const streamEvents = [
  { eventName: "progress", data: JSON.stringify({ step: "accepted", progress: 0 }) },
  { eventName: "progress", data: JSON.stringify({ step: "processing", progress: 50 }) },
  { eventName: "complete", data: JSON.stringify({ step: "finished", progress: 100, result_id: "export-42" }) }
].map((event, index) => ({
  ...event,
  sequence: index + 1,
  timestamp: startedAt + (index + 1) * 500,
  eventId: `event-${index + 1}`,
  raw: `id: event-${index + 1}\nevent: ${event.eventName}\ndata: ${event.data}\n\n`
}));

export const previewRequests = [
  { label: "JSON request and response", record: request("json") },
  {
    label: "HTTP 422 · Validation error",
    record: request("validation-error", {
      status: { kind: "success", code: 422 },
      responseBody: JSON.stringify({
        error: {
          code: "validation_failed",
          message: "One or more items could not be ordered.",
          fields: [{ path: "items[0].quantity", message: "Only one item is currently available.", available: 1 }]
        },
        request_id: "preview-request-002"
      })
    })
  },
  {
    label: "Server-sent events",
    record: request("events", {
      method: "GET",
      url: "https://api.example.com/v1/exports/export-42/events",
      requestHeaders: [{ name: "Accept", value: "text/event-stream" }],
      requestBody: null,
      responseHeaders: [
        { name: "Content-Type", value: "text/event-stream" },
        { name: "Cache-Control", value: "no-cache" }
      ],
      responseBody: null,
      status: { kind: "success", code: 200 },
      endedAt: startedAt + 1800,
      updatedAt: startedAt + 1800,
      streamEvents,
      streamEventCount: streamEvents.length,
      streamClosed: { timestamp: startedAt + 1800, reason: "completed", totalEvents: streamEvents.length }
    })
  },
  {
    label: "Connection failure",
    record: request("connection-failure", {
      method: "GET",
      url: "https://api.example.com/v1/catalog?category=stationery&sort=newest&include=availability,images,dimensions,shipping-estimates&locale=en-US",
      requestHeaders: [{ name: "Accept", value: "application/json" }],
      requestBody: null,
      responseHeaders: [],
      responseBody: null,
      hasReceivedResponse: false,
      status: { kind: "failure", message: "Connection timed out while connecting to api.example.com." },
      endedAt: startedAt + 10000,
      updatedAt: startedAt + 10000
    })
  }
];
