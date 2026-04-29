import type {
  Header,
  InspectorRecord,
  RequestRecord,
  RequestStatus,
  StreamEventRecord,
  WebSocketMessageRecord,
  WebSocketRecord
} from "./cdp";

export function makeCurlCommand(request: RequestRecord): string {
  const warnings: string[] = [];
  const parts = [
    `--request ${singleQuoted(request.method)}`,
    `--url ${singleQuoted(request.url)}`,
    ...request.requestHeaders.map((header) => `--header ${singleQuoted(`${header.name}: ${header.value}`)}`)
  ];

  if (request.requestBody != null && request.requestBody.length > 0) {
    const encoding = request.requestBodyEncoding?.toLowerCase();
    if (encoding === "base64") {
      const decoded = decodeBase64Bytes(request.requestBody);
      if (decoded == null) {
        warnings.push("Unable to decode base64 body - copied data uses raw text");
        parts.push(`--data-binary ${singleQuoted(request.requestBody)}`);
      } else {
        parts.push(`--data-binary ${makeBinaryLiteral(decoded)}`);
      }
    } else {
      parts.push(`--data-binary ${singleQuoted(request.requestBody)}`);
    }
  }

  const command = joinCurlParts(parts);
  if (warnings.length === 0) return command;
  return [...warnings.map((warning) => `# ${warning}`), command].join("\n");
}

export function streamEventsRaw(events: StreamEventRecord[]): string {
  return events.map((event) => event.raw.replace(/\n+$/u, "") + "\n\n").join("");
}

export function buildHar(records: InspectorRecord[]): string {
  const entries = records
    .map((record) => (record.kind === "request" ? requestToEntry(record) : webSocketToEntry(record)))
    .sort((a, b) => a.startedDateTime.localeCompare(b.startedDateTime));
  return JSON.stringify(
    {
      log: {
        version: "1.2",
        creator: {
          name: "Snap-O",
          version: "electron"
        },
        pages: [],
        entries
      }
    },
    null,
    2
  );
}

export function harFileName(entryCount: number, now = new Date()): string {
  const stamp = [
    now.getFullYear(),
    `${now.getMonth() + 1}`.padStart(2, "0"),
    `${now.getDate()}`.padStart(2, "0"),
    "-",
    `${now.getHours()}`.padStart(2, "0"),
    `${now.getMinutes()}`.padStart(2, "0"),
    `${now.getSeconds()}`.padStart(2, "0")
  ].join("");
  return entryCount <= 1 ? `snapo-request-${stamp}.har` : `snapo-requests-${entryCount}-${stamp}.har`;
}

function requestToEntry(request: RequestRecord): HarEntry {
  const responsePayload = requestResponsePayload(request);
  return {
    startedDateTime: new Date(request.startedAt).toISOString(),
    time: requestTimeMs(request),
    request: {
      method: request.method || "GET",
      url: request.url || "about:blank",
      httpVersion: "unknown",
      headers: toHarHeaders(request.requestHeaders, "request"),
      queryString: queryStringFor(request.url),
      cookies: [],
      headersSize: -1,
      bodySize: requestBodySize(request),
      postData:
        request.requestBody == null || request.requestBody.length === 0
          ? undefined
          : {
              mimeType: contentTypeFromHeaders(request.requestHeaders) ?? "x-unknown",
              text: request.requestBody
            }
    },
    response: {
      status: statusCode(request.status),
      statusText: statusText(request.status),
      httpVersion: "unknown",
      headers: toHarHeaders(request.responseHeaders, "response"),
      cookies: [],
      content: responsePayload,
      redirectURL: headerValue(request.responseHeaders, "Location") ?? "",
      headersSize: -1,
      bodySize: responsePayload.size,
      _error: request.status.kind === "failure" ? (request.status.message ?? "failed") : undefined
    },
    cache: {},
    timings: {
      blocked: -1,
      dns: -1,
      connect: -1,
      send: -1,
      wait: -1,
      receive: -1,
      ssl: -1
    }
  };
}

function webSocketToEntry(webSocket: WebSocketRecord): HarEntry {
  const duration = requestTimeMs(webSocket);
  return {
    startedDateTime: new Date(webSocket.startedAt).toISOString(),
    time: duration,
    request: {
      method: "GET",
      url: webSocket.url || `ws://${webSocket.socketId}`,
      httpVersion: "HTTP/1.1",
      headers: toHarHeaders(webSocket.requestHeaders, "request"),
      queryString: queryStringFor(webSocket.url),
      cookies: [],
      headersSize: -1,
      bodySize: 0
    },
    response: {
      status: statusCode(webSocket.status),
      statusText: statusText(webSocket.status),
      httpVersion: "HTTP/1.1",
      headers: toHarHeaders(webSocket.responseHeaders, "response"),
      cookies: [],
      content: {
        size: 0,
        mimeType: "x-unknown"
      },
      redirectURL: "",
      headersSize: -1,
      bodySize: 0,
      _error: webSocket.status.kind === "failure" ? (webSocket.status.message ?? "failed") : undefined
    },
    cache: {},
    timings: {
      blocked: -1,
      dns: -1,
      connect: -1,
      send: 0,
      wait: duration,
      receive: 0,
      ssl: -1
    },
    _resourceType: "websocket",
    _webSocketMessages: webSocket.messages.map(webSocketMessageToHar)
  };
}

function webSocketMessageToHar(message: WebSocketMessageRecord): HarWebSocketMessage {
  return {
    type: message.direction === "outgoing" ? "send" : "receive",
    time: message.timestamp / 1000,
    opcode: webSocketOpcode(message.opcode),
    data: message.preview ?? ""
  };
}

function requestResponsePayload(request: RequestRecord): HarContent {
  const bodyText =
    request.responseBody ?? (request.streamEvents.length > 0 ? streamEventsRaw(request.streamEvents) : null);
  const mimeType =
    contentTypeFromHeaders(request.responseHeaders) ??
    (request.streamEvents.length > 0 ? "text/event-stream" : "x-unknown");
  const fromStreamEvents = request.responseBody == null && request.streamEvents.length > 0;
  const encoding = responseEncoding(mimeType, bodyText, fromStreamEvents, request);
  return {
    size: responseContentSize(bodyText, encoding, request),
    mimeType,
    text: bodyText ?? undefined,
    encoding: encoding ?? undefined
  };
}

function responseEncoding(
  mimeType: string,
  bodyText: string | null,
  fromStreamEvents: boolean,
  request: RequestRecord
): string | null {
  if (bodyText == null || fromStreamEvents) return null;
  if (request.responseBodyBase64Encoded === true) return "base64";
  if (isTextLikeMimeType(mimeType)) return null;
  return isLikelyBase64(bodyText) ? "base64" : null;
}

function responseContentSize(bodyText: string | null, encoding: string | null, request: RequestRecord): number {
  if (request.encodedDataLength != null && request.encodedDataLength >= 0) return request.encodedDataLength;
  if (bodyText == null) return -1;
  if (encoding === "base64") return decodeBase64Bytes(bodyText)?.byteLength ?? -1;
  return new TextEncoder().encode(bodyText).byteLength;
}

function requestBodySize(request: RequestRecord): number {
  if (request.requestBody == null) return -1;
  return new TextEncoder().encode(request.requestBody).byteLength;
}

function requestTimeMs(record: RequestRecord | WebSocketRecord): number {
  return Math.max(0, (record.endedAt ?? record.updatedAt) - record.startedAt);
}

function statusCode(status: RequestStatus): number {
  if (status.kind === "success") return status.code;
  return 0;
}

function statusText(status: RequestStatus): string {
  if (status.kind === "failure") return status.message ?? "";
  return "";
}

function toHarHeaders(headers: Header[], context: "request" | "response"): HarHeader[] {
  return headers
    .filter((header) => !shouldDropHeader(header.name, context))
    .map((header) => ({ name: header.name, value: header.value }));
}

function shouldDropHeader(name: string, context: "request" | "response"): boolean {
  if (context === "request") return equalsHeader(name, "Authorization") || equalsHeader(name, "Cookie");
  return equalsHeader(name, "Set-Cookie");
}

function headerValue(headers: Header[], name: string): string | null {
  return headers.find((header) => equalsHeader(header.name, name))?.value ?? null;
}

function contentTypeFromHeaders(headers: Header[]): string | null {
  return headerValue(headers, "Content-Type")?.split(";")[0]?.trim().toLowerCase() || null;
}

function queryStringFor(url: string): HarNameValue[] {
  try {
    const parsed = new URL(url);
    return [...parsed.searchParams.entries()].map(([name, value]) => ({ name, value }));
  } catch {
    return [];
  }
}

function webSocketOpcode(opcode: string): number {
  switch (opcode.toLowerCase()) {
    case "text":
      return 1;
    case "binary":
      return 2;
    case "close":
      return 8;
    case "ping":
      return 9;
    case "pong":
      return 10;
    default:
      return Number.parseInt(opcode, 10) || -1;
  }
}

function isTextLikeMimeType(value: string): boolean {
  return (
    value.startsWith("text/") ||
    value.includes("json") ||
    value.includes("xml") ||
    value.includes("html") ||
    value.includes("javascript") ||
    value.includes("graphql") ||
    value.includes("x-www-form-urlencoded")
  );
}

function isLikelyBase64(value: string): boolean {
  const normalized = value.replace(/\s+/gu, "");
  if (normalized.length < 16 || normalized.length % 4 !== 0) return false;
  if (!/^[0-9A-Za-z+/=]+$/u.test(normalized)) return false;
  return decodeBase64Bytes(normalized) != null;
}

function decodeBase64Bytes(value: string): Uint8Array | null {
  try {
    const binary = atob(value.replace(/\s+/gu, ""));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
}

function joinCurlParts(parts: string[]): string {
  if (parts.length === 0) return "curl";
  const [first, second, ...remaining] = parts;
  let firstLine = `curl ${first}`;
  if (second != null) firstLine += ` ${second}`;
  if (remaining.length === 0) return firstLine;
  return [
    `${firstLine} \\`,
    ...remaining.map((part, index) => `  ${part}${index === remaining.length - 1 ? "" : " \\"}`)
  ].join("\n");
}

function singleQuoted(value: string): string {
  if (value.length === 0) return "''";
  return `'${value.replace(/'/gu, "'\"'\"'")}'`;
}

function makeBinaryLiteral(data: Uint8Array): string {
  let out = "$'";
  for (const byte of data) {
    if (byte === 0x07) out += "\\a";
    else if (byte === 0x08) out += "\\b";
    else if (byte === 0x09) out += "\\t";
    else if (byte === 0x0a) out += "\\n";
    else if (byte === 0x0b) out += "\\v";
    else if (byte === 0x0c) out += "\\f";
    else if (byte === 0x0d) out += "\\r";
    else if (byte === 0x5c) out += "\\\\";
    else if (byte === 0x27) out += "\\'";
    else if (byte >= 0x20 && byte <= 0x7e) out += String.fromCharCode(byte);
    else out += `\\x${byte.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return `${out}'`;
}

function equalsHeader(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

interface HarEntry {
  startedDateTime: string;
  time: number;
  request: HarRequest;
  response: HarResponse;
  cache: Record<string, never>;
  timings: HarTimings;
  _resourceType?: string;
  _webSocketMessages?: HarWebSocketMessage[];
}

interface HarRequest {
  method: string;
  url: string;
  httpVersion: string;
  headers: HarHeader[];
  queryString: HarNameValue[];
  cookies: HarCookie[];
  headersSize: number;
  bodySize: number;
  postData?: HarPostData;
}

interface HarResponse {
  status: number;
  statusText: string;
  httpVersion: string;
  headers: HarHeader[];
  cookies: HarCookie[];
  content: HarContent;
  redirectURL: string;
  headersSize: number;
  bodySize: number;
  _error?: string;
}

interface HarHeader {
  name: string;
  value: string;
}

interface HarNameValue {
  name: string;
  value: string;
}

type HarCookie = HarNameValue;

interface HarContent {
  size: number;
  mimeType: string;
  text?: string;
  encoding?: string;
}

interface HarPostData {
  mimeType: string;
  text: string;
}

interface HarTimings {
  blocked: number;
  dns: number;
  connect: number;
  send: number;
  wait: number;
  receive: number;
  ssl: number;
}

interface HarWebSocketMessage {
  type: string;
  time: number;
  opcode: number;
  data: string;
}
