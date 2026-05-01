import type { CdpMessage, RequestBodies, SnapOServer } from "./bridge-types";
import type { Protocol } from "devtools-protocol";

type RequestWillBeSentEvent = Partial<Protocol.Network.RequestWillBeSentEvent> & Record<string, unknown>;
type ResponseReceivedEvent = Partial<Protocol.Network.ResponseReceivedEvent> & Record<string, unknown>;
type LoadingFinishedEvent = Partial<Protocol.Network.LoadingFinishedEvent> & Record<string, unknown>;
type LoadingFailedEvent = Partial<Protocol.Network.LoadingFailedEvent> & Record<string, unknown>;
type EventSourceMessageReceivedEvent = Partial<Protocol.Network.EventSourceMessageReceivedEvent> &
  Record<string, unknown>;
type WebSocketCreatedEvent = Partial<Protocol.Network.WebSocketCreatedEvent> & Record<string, unknown>;
type WebSocketHandshakeResponseReceivedEvent = Partial<Protocol.Network.WebSocketHandshakeResponseReceivedEvent> &
  Record<string, unknown>;
type WebSocketFrameEvent =
  | (Partial<Protocol.Network.WebSocketFrameSentEvent> & Record<string, unknown>)
  | (Partial<Protocol.Network.WebSocketFrameReceivedEvent> & Record<string, unknown>);
type WebSocketClosedEvent = Partial<Protocol.Network.WebSocketClosedEvent> & Record<string, unknown>;
type WebSocketFrameErrorEvent = Partial<Protocol.Network.WebSocketFrameErrorEvent> & Record<string, unknown>;

export interface Header {
  name: string;
  value: string;
}

export type RequestStatus =
  | { kind: "pending" }
  | { kind: "success"; code: number }
  | { kind: "failure"; message?: string | null };

export interface RequestRecord {
  kind: "request";
  server: ServerId;
  requestId: string;
  method: string;
  url: string;
  requestHeaders: Header[];
  responseHeaders: Header[];
  status: RequestStatus;
  startedAt: number;
  endedAt?: number;
  encodedDataLength?: number;
  requestHasPostData?: boolean | null;
  requestBodySize?: number | null;
  requestBody?: string | null;
  requestBodyEncoding?: string | null;
  responseBody?: string | null;
  responseBodyBase64Encoded?: boolean | null;
  responseType?: string | null;
  streamEvents: StreamEventRecord[];
  streamClosed?: StreamClosedRecord;
  updatedAt: number;
}

export interface WebSocketRecord {
  kind: "websocket";
  server: ServerId;
  socketId: string;
  method: string;
  url: string;
  requestHeaders: Header[];
  responseHeaders: Header[];
  status: RequestStatus;
  startedAt: number;
  endedAt?: number;
  messages: WebSocketMessageRecord[];
  opened?: WebSocketOpenedRecord | null;
  closeRequested?: WebSocketCloseRequestedRecord | null;
  closing?: WebSocketCloseRecord | null;
  closed?: WebSocketCloseRecord | null;
  cancelled?: WebSocketCancelledRecord | null;
  failed?: WebSocketFailedRecord | null;
  closeReason?: string | null;
  updatedAt: number;
}

export interface StreamEventRecord {
  sequence: number;
  timestamp: number;
  eventName?: string | null;
  eventId?: string | null;
  lastEventId?: string | null;
  retryMillis?: number | null;
  comment?: string | null;
  data?: string | null;
  raw: string;
}

export interface StreamClosedRecord {
  timestamp: number;
  reason: string;
  message?: string | null;
  totalEvents?: number;
  totalBytes?: number;
}

export interface WebSocketMessageRecord {
  id: string;
  direction: "outgoing" | "incoming";
  opcode: string;
  preview?: string | null;
  payloadSize?: number | null;
  timestamp: number;
  enqueued?: boolean | null;
}

export interface WebSocketOpenedRecord {
  timestamp: number;
  code: number;
}

export interface WebSocketCloseRequestedRecord {
  timestamp: number;
  code: number;
  reason?: string | null;
  initiated: string;
  accepted: boolean;
}

export interface WebSocketCloseRecord {
  timestamp: number;
  code: number;
  reason?: string | null;
}

export interface WebSocketCancelledRecord {
  timestamp: number;
}

export interface WebSocketFailedRecord {
  timestamp: number;
  message?: string | null;
}

export interface InspectorDataState {
  servers: SnapOServer[];
  requests: Map<string, RequestRecord>;
  webSockets: Map<string, WebSocketRecord>;
}

export interface ServerId {
  deviceId: string;
  socketName: string;
}

export type InspectorRecord = RequestRecord | WebSocketRecord;

export function createEmptyInspectorState(): InspectorDataState {
  return {
    servers: [],
    requests: new Map(),
    webSockets: new Map()
  };
}

export function reduceCdpMessage(state: InspectorDataState, server: ServerId, message: CdpMessage): InspectorDataState {
  if (message.method == null || message.params == null) return state;
  const now = Date.now();
  switch (message.method) {
    case "Network.requestWillBeSent":
      return reduceRequestWillBeSent(state, server, message.params as RequestWillBeSentEvent, now);
    case "Network.responseReceived":
      return reduceResponseReceived(state, server, message.params as ResponseReceivedEvent, now);
    case "Network.loadingFinished":
      return reduceLoadingFinished(state, server, message.params as LoadingFinishedEvent, now);
    case "Network.loadingFailed":
      return reduceLoadingFailed(state, server, message.params as LoadingFailedEvent, now);
    case "Network.eventSourceMessageReceived":
      return reduceEventSourceMessage(state, server, message.params as EventSourceMessageReceivedEvent, now);
    case "Network.webSocketCreated":
      return reduceWebSocketCreated(state, server, message.params as WebSocketCreatedEvent, now);
    case "Network.webSocketHandshakeResponseReceived":
      return reduceWebSocketHandshakeResponse(
        state,
        server,
        message.params as WebSocketHandshakeResponseReceivedEvent,
        now
      );
    case "Network.webSocketFrameSent":
      return appendWebSocketMessage(state, server, message.params as WebSocketFrameEvent, "outgoing", now);
    case "Network.webSocketFrameReceived":
      return appendWebSocketMessage(state, server, message.params as WebSocketFrameEvent, "incoming", now);
    case "Network.webSocketClosed":
      return reduceWebSocketClosed(state, server, message.params as WebSocketClosedEvent, now);
    case "Network.webSocketFrameError":
      return reduceWebSocketFrameError(state, server, message.params as WebSocketFrameErrorEvent, now);
    default:
      return state;
  }
}

function reduceRequestWillBeSent(
  state: InspectorDataState,
  server: ServerId,
  params: RequestWillBeSentEvent,
  now: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const hasPostData = booleanAt(params, "request.hasPostData") ?? false;
    const postDataLength = numberAt(params, "request.postDataLength");
    return {
      ...requestDefaults(existing, server, requestId(params), now),
      method: params.request?.method ?? existing?.method ?? "?",
      url: params.request?.url ?? existing?.url ?? `Request ${requestId(params)}`,
      requestHeaders: headersFrom(recordFromProtocolHeaders(params.request?.headers)),
      requestHasPostData: hasPostData,
      requestBodySize: postDataLength ?? (hasPostData ? -1 : 0),
      requestBodyEncoding: stringAt(params, "request.postDataEncoding") ?? existing?.requestBodyEncoding,
      startedAt: wallTimeMs(params) ?? existing?.startedAt ?? now,
      updatedAt: now
    };
  });
}

function reduceResponseReceived(
  state: InspectorDataState,
  server: ServerId,
  params: ResponseReceivedEvent,
  now: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const status = params.response?.status;
    return {
      ...requestDefaults(existing, server, requestId(params), now),
      responseHeaders: headersFrom(recordFromProtocolHeaders(params.response?.headers)),
      status: status == null ? (existing?.status ?? { kind: "pending" }) : { kind: "success", code: status },
      endedAt: existing?.endedAt,
      encodedDataLength: params.response?.encodedDataLength ?? existing?.encodedDataLength,
      responseType: stringAt(params, "type") ?? existing?.responseType,
      updatedAt: now
    };
  });
}

function reduceLoadingFinished(
  state: InspectorDataState,
  server: ServerId,
  params: LoadingFinishedEvent,
  now: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), now);
    const encodedDataLength = params.encodedDataLength ?? existing?.encodedDataLength;
    const status = base.status.kind === "success" ? base.status : { kind: "success" as const, code: 200 };
    return {
      ...base,
      status,
      endedAt: now,
      encodedDataLength,
      streamClosed: isLikelyStreamingRequest(base)
        ? {
            timestamp: now,
            reason: "completed",
            totalEvents: base.streamEvents.length,
            totalBytes: encodedDataLength
          }
        : base.streamClosed,
      updatedAt: now
    };
  });
}

function reduceLoadingFailed(
  state: InspectorDataState,
  server: ServerId,
  params: LoadingFailedEvent,
  now: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), now);
    const message = params.errorText ?? stringAt(params, "type");
    const isStreamFailure = isLikelyStreamingRequest(base) || stringAt(params, "type")?.toLowerCase() === "eventsource";
    return {
      ...base,
      status: {
        kind: "failure",
        message
      },
      endedAt: now,
      streamClosed: isStreamFailure
        ? {
            timestamp: now,
            reason: "error",
            message,
            totalEvents: base.streamEvents.length,
            totalBytes: 0
          }
        : base.streamClosed,
      updatedAt: now
    };
  });
}

function reduceEventSourceMessage(
  state: InspectorDataState,
  server: ServerId,
  params: EventSourceMessageReceivedEvent,
  now: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), now);
    const raw = stringAt(params, "data") ?? "";
    const parsed = parseSseRaw(raw);
    const eventName = parsed.eventName ?? (parsed.sawSseField ? null : params.eventName);
    const data = parsed.data ?? (parsed.sawSseField ? null : params.data);
    const nextEvent: StreamEventRecord = {
      sequence: numericEventSequence(params.eventId) ?? base.streamEvents.length + 1,
      timestamp: now,
      eventName,
      eventId: params.eventId,
      lastEventId: parsed.lastEventId,
      retryMillis: parsed.retryMillis,
      comment: parsed.comment,
      data,
      raw
    };
    return {
      ...base,
      status: { kind: "pending" },
      streamEvents: [...base.streamEvents, nextEvent],
      updatedAt: now
    };
  });
}

function reduceWebSocketCreated(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketCreatedEvent,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => ({
    ...webSocketDefaults(existing, server, requestId(params), now),
    method: webSocketMethod(params.url ?? null),
    url: params.url ?? existing?.url ?? `websocket://${requestId(params)}`,
    requestHeaders: headersFrom(recordFromProtocolHeaders(plainObjectAt(params, "headers"))),
    startedAt: wallTimeMs(params) ?? existing?.startedAt ?? now,
    updatedAt: now
  }));
}

function reduceWebSocketHandshakeResponse(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketHandshakeResponseReceivedEvent,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const status = params.response?.status;
    return {
      ...webSocketDefaults(existing, server, requestId(params), now),
      responseHeaders: headersFrom(recordFromProtocolHeaders(params.response?.headers)),
      status: status == null ? (existing?.status ?? { kind: "pending" }) : { kind: "success", code: status },
      opened: status == null ? existing?.opened : { timestamp: now, code: status },
      updatedAt: now
    };
  });
}

function reduceWebSocketClosed(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketClosedEvent,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const code = numberAt(params, "code");
    const reason = stringAt(params, "reason");
    const base = webSocketDefaults(existing, server, requestId(params), now);
    if (reason?.toLowerCase() === "cancelled" && code == null) {
      return {
        ...base,
        status: { kind: "failure", message: "Cancelled" },
        cancelled: { timestamp: now },
        endedAt: now,
        updatedAt: now
      };
    }
    return {
      ...base,
      status: { kind: "success", code: code ?? 1000 },
      closed: { timestamp: now, code: code ?? 1000, reason },
      closeReason: reason,
      endedAt: now,
      updatedAt: now
    };
  });
}

function reduceWebSocketFrameError(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketFrameErrorEvent,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => ({
    ...webSocketDefaults(existing, server, requestId(params), now),
    status: { kind: "failure", message: params.errorMessage },
    failed: { timestamp: now, message: params.errorMessage },
    endedAt: now,
    updatedAt: now
  }));
}

export function applyRequestBodies(record: RequestRecord, bodies: RequestBodies): RequestRecord {
  return {
    ...record,
    requestBody: bodies.requestBody ?? record.requestBody,
    responseBody: bodies.responseBody ?? record.responseBody,
    responseBodyBase64Encoded: bodies.responseBodyBase64Encoded ?? record.responseBodyBase64Encoded
  };
}

export function recordId(record: InspectorRecord): string {
  if (record.kind === "request") return requestRecordKey(record.server, record.requestId);
  return webSocketRecordKey(record.server, record.socketId);
}

export function requestRecordKey(server: ServerId, requestId: string): string {
  return `${server.deviceId}\u0000${server.socketName}\u0000request\u0000${requestId}`;
}

export function webSocketRecordKey(server: ServerId, socketId: string): string {
  return `${server.deviceId}\u0000${server.socketName}\u0000websocket\u0000${socketId}`;
}

export function serverMatches(a: ServerId | null, b: ServerId): boolean {
  return a == null || (a.deviceId === b.deviceId && a.socketName === b.socketName);
}

function updateRequest(
  state: InspectorDataState,
  server: ServerId,
  requestIdValue: string,
  transform: (existing: RequestRecord | undefined) => RequestRecord
): InspectorDataState {
  const existing = state.requests.get(requestRecordKey(server, requestIdValue));
  const updated = transform(existing);
  const requests = new Map(state.requests);
  requests.set(requestRecordKey(updated.server, updated.requestId), updated);
  return { ...state, requests };
}

function updateWebSocket(
  state: InspectorDataState,
  server: ServerId,
  socketId: string,
  transform: (existing: WebSocketRecord | undefined) => WebSocketRecord
): InspectorDataState {
  const existing = state.webSockets.get(webSocketRecordKey(server, socketId));
  const updated = transform(existing);
  const webSockets = new Map(state.webSockets);
  webSockets.set(webSocketRecordKey(updated.server, updated.socketId), updated);
  return { ...state, webSockets };
}

function requestDefaults(
  existing: RequestRecord | undefined,
  server: ServerId,
  requestIdValue: string,
  now: number
): RequestRecord {
  return (
    existing ?? {
      kind: "request",
      server,
      requestId: requestIdValue,
      method: "?",
      url: `Request ${requestIdValue}`,
      requestHeaders: [],
      responseHeaders: [],
      status: { kind: "pending" },
      startedAt: now,
      streamEvents: [],
      updatedAt: now
    }
  );
}

function webSocketDefaults(
  existing: WebSocketRecord | undefined,
  server: ServerId,
  socketId: string,
  now: number
): WebSocketRecord {
  return (
    existing ?? {
      kind: "websocket",
      server,
      socketId,
      method: "WS",
      url: `websocket://${socketId}`,
      requestHeaders: [],
      responseHeaders: [],
      status: { kind: "pending" },
      startedAt: now,
      messages: [],
      updatedAt: now
    }
  );
}

function appendWebSocketMessage(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  direction: "outgoing" | "incoming",
  now: number
): InspectorDataState {
  const opcode = numberAt(params, "response.opcode");
  const closeCode = numberAt(params, "response.closeCode");
  if (opcode === 8 && closeCode != null) {
    return direction === "outgoing"
      ? reduceWebSocketCloseRequested(state, server, params, now)
      : reduceWebSocketClosing(state, server, params, now);
  }

  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), now);
    const message: WebSocketMessageRecord = {
      id: `${base.socketId}:${base.messages.length + 1}`,
      direction,
      opcode: opcodeLabel(opcode),
      preview: stringAt(params, "response.payloadData"),
      payloadSize: numberAt(params, "response.payloadSize"),
      timestamp: now,
      enqueued: booleanAt(params, "response.enqueued")
    };
    return {
      ...base,
      messages: [...base.messages, message].sort((left, right) => left.timestamp - right.timestamp),
      updatedAt: now
    };
  });
}

function reduceWebSocketCloseRequested(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), now);
    return {
      ...base,
      closeRequested: {
        timestamp: now,
        code: numberAt(params, "response.closeCode") ?? 1000,
        reason: stringAt(params, "response.closeReason"),
        initiated: stringAt(params, "response.closeInitiated") ?? "client",
        accepted: booleanAt(params, "response.closeAccepted") ?? true
      },
      updatedAt: now
    };
  });
}

function reduceWebSocketClosing(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  now: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const code = numberAt(params, "response.closeCode") ?? 1000;
    const reason = stringAt(params, "response.closeReason");
    return {
      ...webSocketDefaults(existing, server, requestId(params), now),
      status: { kind: "success", code },
      closing: { timestamp: now, code, reason },
      closeReason: reason,
      endedAt: now,
      updatedAt: now
    };
  });
}

function requestId(params: Record<string, unknown>): string {
  return stringAt(params, "requestId") ?? "unknown";
}

function headersFrom(headers: Record<string, unknown> | null): Header[] {
  if (headers == null) return [];
  return Object.entries(headers).flatMap(([name, value]) =>
    String(value)
      .split("\n")
      .map((line) => ({ name, value: line }))
  );
}

function isLikelyStreamingRequest(record: RequestRecord): boolean {
  if (record.streamEvents.length > 0) return true;
  if (record.responseType?.toLowerCase() === "eventsource") return true;
  return hasEventStreamHeader(record.responseHeaders) || hasEventStreamHeader(record.requestHeaders);
}

function hasEventStreamHeader(headers: Header[]): boolean {
  return headers.some((header) => {
    const name = header.name.toLowerCase();
    const value = header.value.toLowerCase();
    return (name === "content-type" || name === "accept") && value.includes("text/event-stream");
  });
}

function recordFromProtocolHeaders(headers: unknown): Record<string, unknown> | null {
  return headers != null && typeof headers === "object" && !Array.isArray(headers)
    ? (headers as Record<string, unknown>)
    : null;
}

interface ParsedSseRaw {
  sawSseField: boolean;
  eventName: string | null;
  data: string | null;
  lastEventId: string | null;
  retryMillis: number | null;
  comment: string | null;
}

function parseSseRaw(raw: string): ParsedSseRaw {
  let sawSseField = false;
  let eventName: string | null = null;
  let lastEventId: string | null = null;
  let retryMillis: number | null = null;
  const comments: string[] = [];
  const dataLines: string[] = [];

  for (const line of raw.split(/\r?\n/u)) {
    if (line.length === 0) continue;
    if (line.startsWith(":")) {
      sawSseField = true;
      const comment = line.slice(1).trim();
      if (comment.length > 0) comments.push(comment);
      continue;
    }

    const separatorIndex = line.indexOf(":");
    const field = separatorIndex === -1 ? line : line.slice(0, separatorIndex);
    const rawValue = separatorIndex === -1 ? "" : line.slice(separatorIndex + 1);
    const value = rawValue.startsWith(" ") ? rawValue.slice(1) : rawValue;

    if (field === "event") {
      sawSseField = true;
      eventName = value;
    } else if (field === "data") {
      sawSseField = true;
      dataLines.push(value);
    } else if (field === "id") {
      sawSseField = true;
      lastEventId = value;
    } else if (field === "retry") {
      sawSseField = true;
      const parsed = Number.parseInt(value, 10);
      retryMillis = Number.isFinite(parsed) ? parsed : null;
    }
  }

  return {
    sawSseField,
    eventName,
    data: dataLines.length === 0 ? (raw.length === 0 ? "" : null) : dataLines.join("\n"),
    lastEventId,
    retryMillis,
    comment: comments.length === 0 ? null : comments.join("\n")
  };
}

function numericEventSequence(eventId: string | null | undefined): number | null {
  if (eventId == null || eventId.trim().length === 0) return null;
  const parsed = Number.parseInt(eventId, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function webSocketMethod(url: string | null): string {
  if (url == null) return "WS";
  if (url.startsWith("wss:") || url.startsWith("https:")) return "WSS";
  return "WS";
}

function opcodeLabel(opcode: number | null): string {
  switch (opcode) {
    case 1:
      return "text";
    case 2:
      return "binary";
    case 8:
      return "close";
    case 9:
      return "ping";
    case 10:
      return "pong";
    default:
      return "text";
  }
}

function wallTimeMs(params: Record<string, unknown>): number | undefined {
  const wallTime = numberAt(params, "wallTime");
  return wallTime == null ? undefined : Math.round(wallTime * 1000);
}

function stringAt(record: Record<string, unknown>, path: string): string | null {
  const value = valueAt(record, path);
  return typeof value === "string" ? value : null;
}

function numberAt(record: Record<string, unknown>, path: string): number | null {
  const value = valueAt(record, path);
  return typeof value === "number" ? value : null;
}

function booleanAt(record: Record<string, unknown>, path: string): boolean | null {
  const value = valueAt(record, path);
  return typeof value === "boolean" ? value : null;
}

function plainObjectAt(record: Record<string, unknown>, path: string): Record<string, unknown> | null {
  const value = valueAt(record, path);
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function valueAt(record: Record<string, unknown>, path: string): unknown {
  let current: unknown = record;
  for (const segment of path.split(".")) {
    if (current == null || typeof current !== "object" || Array.isArray(current)) return undefined;
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}
