import type { RequestStatus } from "../../../network/cdp";

export function formatTiming(startedAt: number, endedAt: number | undefined, status: RequestStatus): string {
  const startSegment = `Started ${formatRelative(startedAt)} at ${formatTimeWithMillis(startedAt)}`;
  if (status.kind === "pending" || endedAt == null) return startSegment;
  return `${formatDuration(Math.max(0, endedAt - startedAt))} total • ${startSegment}`;
}

export function formatDuration(durationMs: number): string {
  const seconds = durationMs / 1000;
  if (seconds < 1) return `${Math.round(durationMs)} ms`;
  if (seconds < 10) return `${seconds.toFixed(2)} s`;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  return `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s`;
}

export function formatTime(value: number): string {
  return new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(value));
}

function formatTimeWithMillis(value: number): string {
  const date = new Date(value);
  const hours = date.getHours();
  const minutes = `${date.getMinutes()}`.padStart(2, "0");
  const seconds = `${date.getSeconds()}`.padStart(2, "0");
  const millis = `${date.getMilliseconds()}`.padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${millis}`;
}

function formatRelative(value: number): string {
  const seconds = Math.round((Date.now() - value) / 1000);
  if (seconds === 0) return "just now";
  const absoluteSeconds = Math.abs(seconds);
  const isFuture = seconds < 0;
  const [amount, unit] =
    absoluteSeconds < 60
      ? [absoluteSeconds, "s"]
      : absoluteSeconds < 3600
        ? [Math.floor(absoluteSeconds / 60), "m"]
        : absoluteSeconds < 86400
          ? [Math.floor(absoluteSeconds / 3600), "h"]
          : [Math.floor(absoluteSeconds / 86400), "d"];
  return isFuture ? `in ${amount}${unit}` : `${amount}${unit} ago`;
}

export function statusToneClass(code: number): string {
  if (code >= 200 && code <= 299) return "status-success";
  if (code >= 400 && code <= 599) return "status-error";
  if (code >= 300 && code <= 399) return "status-warning";
  return "status-info";
}

export function statusDisplayName(code: number): string {
  const overrides: Record<number, string> = {
    200: "OK",
    201: "Created",
    202: "Accepted",
    204: "No Content",
    301: "Moved Permanently",
    302: "Found",
    304: "Not Modified",
    307: "Temporary Redirect",
    308: "Permanent Redirect",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    410: "Gone",
    422: "Unprocessable Entity",
    429: "Too Many Requests",
    500: "Internal Server Error",
    501: "Not Implemented",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout"
  };
  return `${code} ${overrides[code] ?? "Done"}`;
}
