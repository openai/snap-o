import type { CdpMessage } from "./bridge-types.js";

export type HeaderContext = "request" | "response";
export type SensitiveHeaderMode = "drop" | "redact";

export const RedactedValue = "[REDACTED]";

export function isSensitiveHeader(name: string, context: HeaderContext): boolean {
  const normalized = name.toLowerCase();
  if (context === "request") return normalized === "authorization" || normalized === "cookie";
  return normalized === "set-cookie";
}

export function sanitizeStringHeaders(
  headers: Record<string, string>,
  context: HeaderContext,
  mode: SensitiveHeaderMode
): Record<string, string> {
  const updated: Record<string, string> = {};
  let changed = false;
  for (const [name, value] of Object.entries(headers)) {
    if (!isSensitiveHeader(name, context)) {
      updated[name] = value;
      continue;
    }
    changed = true;
    if (mode === "redact") updated[name] = RedactedValue;
  }
  return changed ? updated : headers;
}

export function sanitizeCdpMessage(message: CdpMessage, mode: SensitiveHeaderMode): CdpMessage {
  if (message.method == null || message.params == null) return message;
  let params = message.params;
  switch (message.method) {
    case "Network.requestWillBeSent":
      params = sanitizeHeadersAtPath(params, ["request", "headers"], "request", mode);
      break;
    case "Network.responseReceived":
      params = sanitizeHeadersAtPath(params, ["response", "headers"], "response", mode);
      break;
    case "Network.webSocketCreated":
      params = sanitizeHeadersAtPath(params, ["headers"], "request", mode);
      break;
    case "Network.webSocketHandshakeResponseReceived":
      params = sanitizeHeadersAtPath(params, ["response", "headers"], "response", mode);
      break;
    default:
      return message;
  }
  return params === message.params ? message : { ...message, params };
}

function sanitizeHeadersAtPath(
  root: Record<string, unknown>,
  path: string[],
  context: HeaderContext,
  mode: SensitiveHeaderMode
): Record<string, unknown> {
  if (path.length === 0) return sanitizeUnknownHeaders(root, context, mode);
  const [key, ...rest] = path;
  const child = root[key];
  if (!isRecord(child)) return root;
  const next = sanitizeHeadersAtPath(child, rest, context, mode);
  return next === child ? root : { ...root, [key]: next };
}

function sanitizeUnknownHeaders(
  headers: Record<string, unknown>,
  context: HeaderContext,
  mode: SensitiveHeaderMode
): Record<string, unknown> {
  const updated: Record<string, unknown> = {};
  let changed = false;
  for (const [name, value] of Object.entries(headers)) {
    if (!isSensitiveHeader(name, context)) {
      updated[name] = value;
      continue;
    }
    changed = true;
    if (mode === "redact") updated[name] = RedactedValue;
  }
  return changed ? updated : headers;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null && !Array.isArray(value);
}
