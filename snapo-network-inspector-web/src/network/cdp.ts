import type { CdpMessage, RequestBodies, SnapOServer } from "./bridge-types";
import type { Protocol } from "devtools-protocol";
import { isLikelyStreamingRequest } from "./request-classification";

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
  startedAtMonotonic?: number;
  endedAt?: number;
  encodedDataLength?: number;
  requestHasPostData?: boolean | null;
  requestBodySize?: number | null;
  requestBody?: string | null;
  requestBodyEncoding?: string | null;
  responseBody?: string | null;
  responseBodyBase64Encoded?: boolean | null;
  responseType?: string | null;
  hasReceivedResponse?: boolean;
  streamEvents: StreamEventRecord[];
  streamEventCount: number;
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
  startedAtMonotonic?: number;
  endedAt?: number;
  messages: WebSocketMessageRecord[];
  messageCount: number;
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
  latestSequenceByServer: Map<string, number>;
}

export interface ServerId {
  deviceId: string;
  socketName: string;
  instanceId?: string | null;
}

export type InspectorRecord = RequestRecord | WebSocketRecord;

export const inspectorRetentionLimits = {
  records: 2_000,
  streamEventsPerRequest: 1_000,
  webSocketMessagesPerSocket: 2_000
} as const;

export function createEmptyInspectorState(): InspectorDataState {
  return {
    servers: [],
    requests: new Map(),
    webSockets: new Map(),
    latestSequenceByServer: new Map()
  };
}

export function reduceCdpMessage(
  state: InspectorDataState,
  server: ServerId,
  message: CdpMessage,
  receivedAt = Date.now()
): InspectorDataState {
  if (message.method == null || message.params == null) return state;
  const sequencedState = acceptSequence(state, server, message.snapoSequence);
  if (sequencedState == null) return state;

  let reduced: InspectorDataState;
  switch (message.method) {
    case "Network.requestWillBeSent":
      reduced = reduceRequestWillBeSent(sequencedState, server, message.params as RequestWillBeSentEvent, receivedAt);
      break;
    case "Network.responseReceived":
      reduced = reduceResponseReceived(sequencedState, server, message.params as ResponseReceivedEvent, receivedAt);
      break;
    case "Network.loadingFinished":
      reduced = reduceLoadingFinished(sequencedState, server, message.params as LoadingFinishedEvent, receivedAt);
      break;
    case "Network.loadingFailed":
      reduced = reduceLoadingFailed(sequencedState, server, message.params as LoadingFailedEvent, receivedAt);
      break;
    case "Network.eventSourceMessageReceived":
      reduced = reduceEventSourceMessage(
        sequencedState,
        server,
        message.params as EventSourceMessageReceivedEvent,
        receivedAt
      );
      break;
    case "Network.webSocketCreated":
      reduced = reduceWebSocketCreated(sequencedState, server, message.params as WebSocketCreatedEvent, receivedAt);
      break;
    case "Network.webSocketHandshakeResponseReceived":
      reduced = reduceWebSocketHandshakeResponse(
        sequencedState,
        server,
        message.params as WebSocketHandshakeResponseReceivedEvent,
        receivedAt
      );
      break;
    case "Network.webSocketFrameSent":
      reduced = appendWebSocketMessage(
        sequencedState,
        server,
        message.params as WebSocketFrameEvent,
        "outgoing",
        receivedAt
      );
      break;
    case "Network.webSocketFrameReceived":
      reduced = appendWebSocketMessage(
        sequencedState,
        server,
        message.params as WebSocketFrameEvent,
        "incoming",
        receivedAt
      );
      break;
    case "Network.webSocketClosed":
      reduced = reduceWebSocketClosed(sequencedState, server, message.params as WebSocketClosedEvent, receivedAt);
      break;
    case "Network.webSocketFrameError":
      reduced = reduceWebSocketFrameError(
        sequencedState,
        server,
        message.params as WebSocketFrameErrorEvent,
        receivedAt
      );
      break;
    default:
      return state;
  }

  return enforceInspectorRetention(reduced);
}

function reduceRequestWillBeSent(
  state: InspectorDataState,
  server: ServerId,
  params: RequestWillBeSentEvent,
  receivedAt: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const hasPostData = booleanAt(params, "request.hasPostData") ?? false;
    const postDataLength = numberAt(params, "request.postDataLength");
    const startedAt = wallTimeMs(params) ?? existing?.startedAt ?? receivedAt;
    const startedAtMonotonic = monotonicTime(params) ?? existing?.startedAtMonotonic;
    return {
      ...requestDefaults(existing, server, requestId(params), receivedAt),
      method: params.request?.method ?? existing?.method ?? "?",
      url: params.request?.url ?? existing?.url ?? `Request ${requestId(params)}`,
      requestHeaders: headersFrom(recordFromProtocolHeaders(params.request?.headers)),
      requestHasPostData: hasPostData,
      requestBodySize: postDataLength ?? (hasPostData ? -1 : 0),
      requestBodyEncoding: stringAt(params, "request.postDataEncoding") ?? existing?.requestBodyEncoding,
      startedAt,
      startedAtMonotonic,
      updatedAt: startedAt
    };
  });
}

function reduceResponseReceived(
  state: InspectorDataState,
  server: ServerId,
  params: ResponseReceivedEvent,
  receivedAt: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const status = params.response?.status;
    return {
      ...base,
      responseHeaders: headersFrom(recordFromProtocolHeaders(params.response?.headers)),
      status: status == null ? (existing?.status ?? { kind: "pending" }) : { kind: "success", code: status },
      endedAt: existing?.endedAt,
      encodedDataLength: params.response?.encodedDataLength ?? existing?.encodedDataLength,
      responseType: stringAt(params, "type") ?? existing?.responseType,
      hasReceivedResponse: true,
      updatedAt: eventAt
    };
  });
}

function reduceLoadingFinished(
  state: InspectorDataState,
  server: ServerId,
  params: LoadingFinishedEvent,
  receivedAt: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const encodedDataLength = params.encodedDataLength ?? existing?.encodedDataLength;
    const status = base.status.kind === "success" ? base.status : { kind: "success" as const, code: 200 };
    return {
      ...base,
      status,
      endedAt: eventAt,
      encodedDataLength,
      streamClosed: isLikelyStreamingRequest(base)
        ? {
            timestamp: eventAt,
            reason: "completed",
            totalEvents: base.streamEventCount,
            totalBytes: encodedDataLength
          }
        : base.streamClosed,
      updatedAt: eventAt
    };
  });
}

function reduceLoadingFailed(
  state: InspectorDataState,
  server: ServerId,
  params: LoadingFailedEvent,
  receivedAt: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const message = params.errorText ?? stringAt(params, "type");
    const isStreamFailure = isLikelyStreamingRequest(base) || stringAt(params, "type")?.toLowerCase() === "eventsource";
    return {
      ...base,
      status: {
        kind: "failure",
        message
      },
      endedAt: eventAt,
      streamClosed: isStreamFailure
        ? {
            timestamp: eventAt,
            reason: "error",
            message,
            totalEvents: base.streamEventCount,
            totalBytes: 0
          }
        : base.streamClosed,
      updatedAt: eventAt
    };
  });
}

function reduceEventSourceMessage(
  state: InspectorDataState,
  server: ServerId,
  params: EventSourceMessageReceivedEvent,
  receivedAt: number
): InspectorDataState {
  return updateRequest(state, server, requestId(params), (existing) => {
    const base = requestDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const raw = stringAt(params, "data") ?? "";
    const parsed = parseSseRaw(raw);
    const eventName = parsed.eventName ?? (parsed.sawSseField ? null : params.eventName);
    const data = parsed.data ?? (parsed.sawSseField ? null : params.data);
    const nextEvent: StreamEventRecord = {
      sequence: numericEventSequence(params.eventId) ?? base.streamEventCount + 1,
      timestamp: eventAt,
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
      streamEvents: retainNewest([...base.streamEvents, nextEvent], inspectorRetentionLimits.streamEventsPerRequest),
      streamEventCount: base.streamEventCount + 1,
      updatedAt: eventAt
    };
  });
}

function reduceWebSocketCreated(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketCreatedEvent,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const startedAt = wallTimeMs(params) ?? existing?.startedAt ?? receivedAt;
    return {
      ...webSocketDefaults(existing, server, requestId(params), receivedAt),
      method: webSocketMethod(params.url ?? null),
      url: params.url ?? existing?.url ?? `websocket://${requestId(params)}`,
      requestHeaders: headersFrom(recordFromProtocolHeaders(plainObjectAt(params, "headers"))),
      startedAt,
      startedAtMonotonic: monotonicTime(params) ?? existing?.startedAtMonotonic,
      updatedAt: startedAt
    };
  });
}

function reduceWebSocketHandshakeResponse(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketHandshakeResponseReceivedEvent,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const status = params.response?.status;
    return {
      ...base,
      responseHeaders: headersFrom(recordFromProtocolHeaders(params.response?.headers)),
      status: status == null ? (existing?.status ?? { kind: "pending" }) : { kind: "success", code: status },
      opened: status == null ? existing?.opened : { timestamp: eventAt, code: status },
      updatedAt: eventAt
    };
  });
}

function reduceWebSocketClosed(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketClosedEvent,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const code = numberAt(params, "code");
    const reason = stringAt(params, "reason");
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    if (reason?.toLowerCase() === "cancelled" && code == null) {
      return {
        ...base,
        status: { kind: "failure", message: "Cancelled" },
        cancelled: { timestamp: eventAt },
        endedAt: eventAt,
        updatedAt: eventAt
      };
    }
    return {
      ...base,
      status: { kind: "success", code: code ?? 1000 },
      closed: { timestamp: eventAt, code: code ?? 1000, reason },
      closeReason: reason,
      endedAt: eventAt,
      updatedAt: eventAt
    };
  });
}

function reduceWebSocketFrameError(
  state: InspectorDataState,
  server: ServerId,
  params: WebSocketFrameErrorEvent,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    return {
      ...base,
      status: { kind: "failure", message: params.errorMessage },
      failed: { timestamp: eventAt, message: params.errorMessage },
      endedAt: eventAt,
      updatedAt: eventAt
    };
  });
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
  return `${serverDataKey(server)}\u0000request\u0000${requestId}`;
}

export function webSocketRecordKey(server: ServerId, socketId: string): string {
  return `${serverDataKey(server)}\u0000websocket\u0000${socketId}`;
}

export function serverMatches(a: ServerId | null, b: ServerId): boolean {
  return a == null || (a.deviceId === b.deviceId && a.socketName === b.socketName);
}

function acceptSequence(
  state: InspectorDataState,
  server: ServerId,
  sequence: number | undefined
): InspectorDataState | null {
  if (sequence == null || !Number.isSafeInteger(sequence)) return state;

  const key = serverSequenceKey(server);
  const latest = state.latestSequenceByServer.get(key);
  if (latest != null && sequence <= latest) return null;

  const latestSequenceByServer = new Map(state.latestSequenceByServer);
  latestSequenceByServer.set(key, sequence);
  return { ...state, latestSequenceByServer };
}

export function enforceInspectorRetention(
  state: InspectorDataState,
  maxRecords: number = inspectorRetentionLimits.records
): InspectorDataState {
  const overflow = state.requests.size + state.webSockets.size - maxRecords;
  if (overflow <= 0) return state;

  const candidates: Array<{
    key: string;
    kind: InspectorRecord["kind"];
    completed: boolean;
    updatedAt: number;
  }> = [
    ...[...state.requests.entries()].map(([key, record]) => ({
      key,
      kind: record.kind,
      completed: record.endedAt != null || record.status.kind === "failure",
      updatedAt: record.updatedAt
    })),
    ...[...state.webSockets.entries()].map(([key, record]) => ({
      key,
      kind: record.kind,
      completed: record.endedAt != null || record.status.kind === "failure",
      updatedAt: record.updatedAt
    }))
  ].sort((left, right) => {
    if (left.completed !== right.completed) return left.completed ? -1 : 1;
    if (left.updatedAt !== right.updatedAt) return left.updatedAt - right.updatedAt;
    return left.key.localeCompare(right.key);
  });

  const requests = new Map(state.requests);
  const webSockets = new Map(state.webSockets);
  for (const candidate of candidates.slice(0, overflow)) {
    if (candidate.kind === "request") requests.delete(candidate.key);
    else webSockets.delete(candidate.key);
  }
  return { ...state, requests, webSockets };
}

function serverSequenceKey(server: ServerId): string {
  return serverDataKey(server);
}

function serverDataKey(server: ServerId): string {
  return `${server.deviceId}\u0000${server.socketName}\u0000${server.instanceId ?? ""}`;
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
      streamEventCount: 0,
      updatedAt: now
    }
  );
}

function eventTimeMs(
  params: Record<string, unknown>,
  record: Pick<RequestRecord | WebSocketRecord, "startedAt" | "startedAtMonotonic">,
  fallback: number
): number {
  const timestamp = monotonicTime(params);
  if (timestamp != null && record.startedAtMonotonic != null) {
    return Math.round(record.startedAt + (timestamp - record.startedAtMonotonic) * 1_000);
  }
  return wallTimeMs(params) ?? fallback;
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
      messageCount: 0,
      updatedAt: now
    }
  );
}

function appendWebSocketMessage(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  direction: "outgoing" | "incoming",
  receivedAt: number
): InspectorDataState {
  const opcode = numberAt(params, "response.opcode");
  const closeCode = numberAt(params, "response.closeCode");
  if (opcode === 8 && closeCode != null) {
    return direction === "outgoing"
      ? reduceWebSocketCloseRequested(state, server, params, receivedAt)
      : reduceWebSocketClosing(state, server, params, receivedAt);
  }

  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    const message: WebSocketMessageRecord = {
      id: `${base.socketId}:${base.messageCount + 1}`,
      direction,
      opcode: opcodeLabel(opcode),
      preview: stringAt(params, "response.payloadData"),
      payloadSize: numberAt(params, "response.payloadSize"),
      timestamp: eventAt,
      enqueued: booleanAt(params, "response.enqueued")
    };
    return {
      ...base,
      messages: retainNewest(
        [...base.messages, message].sort((left, right) => left.timestamp - right.timestamp),
        inspectorRetentionLimits.webSocketMessagesPerSocket
      ),
      messageCount: base.messageCount + 1,
      updatedAt: eventAt
    };
  });
}

function reduceWebSocketCloseRequested(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    return {
      ...base,
      closeRequested: {
        timestamp: eventAt,
        code: numberAt(params, "response.closeCode") ?? 1000,
        reason: stringAt(params, "response.closeReason"),
        initiated: stringAt(params, "response.closeInitiated") ?? "client",
        accepted: booleanAt(params, "response.closeAccepted") ?? true
      },
      updatedAt: eventAt
    };
  });
}

function reduceWebSocketClosing(
  state: InspectorDataState,
  server: ServerId,
  params: Record<string, unknown>,
  receivedAt: number
): InspectorDataState {
  return updateWebSocket(state, server, requestId(params), (existing) => {
    const code = numberAt(params, "response.closeCode") ?? 1000;
    const reason = stringAt(params, "response.closeReason");
    const base = webSocketDefaults(existing, server, requestId(params), receivedAt);
    const eventAt = eventTimeMs(params, base, receivedAt);
    return {
      ...base,
      status: { kind: "success", code },
      closing: { timestamp: eventAt, code, reason },
      closeReason: reason,
      endedAt: eventAt,
      updatedAt: eventAt
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

function monotonicTime(params: Record<string, unknown>): number | undefined {
  return numberAt(params, "timestamp") ?? undefined;
}

function retainNewest<T>(values: T[], limit: number): T[] {
  return values.length <= limit ? values : values.slice(values.length - limit);
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
