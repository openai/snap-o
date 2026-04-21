import type { Header } from "./cdp";

export interface JsonNode {
  key: string;
  label: string;
  valuePreview?: string;
  type: "object" | "array" | "primitive";
  children: JsonNode[];
}

export interface BodyPayload {
  rawText: string;
  prettyText: string | null;
  isLikelyJson: boolean;
  contentType: string | null;
  encoding: string | null;
  capturedBytes: number;
  totalBytes: number | null;
  base64Encoded: boolean;
}

export function makeBodyPayload(input: {
  body: string | null | undefined;
  headers: Header[];
  encoding?: string | null;
  base64Encoded?: boolean | null;
  totalBytes?: number | null;
}): BodyPayload | null {
  if (input.body == null || input.body.length === 0) return null;
  const contentType = contentTypeFromHeaders(input.headers);
  const base64Encoded = input.base64Encoded === true || input.encoding?.toLowerCase() === "base64";
  const rawText = input.body;
  const prettyText = base64Encoded ? null : prettyJsonOrNull(rawText);
  return {
    rawText,
    prettyText,
    isLikelyJson: prettyText != null || isLikelyJson(rawText, contentType),
    contentType,
    encoding: base64Encoded ? "base64" : input.encoding ?? null,
    capturedBytes: bodyByteLength(rawText, base64Encoded),
    totalBytes: input.totalBytes ?? null,
    base64Encoded
  };
}

export function contentTypeFromHeaders(headers: Header[]): string | null {
  const raw = headers.find((header) => header.name.toLowerCase() === "content-type")?.value;
  return raw?.split(";")[0]?.trim().toLowerCase() || null;
}

export function isImagePayload(payload: BodyPayload): boolean {
  return payload.contentType?.startsWith("image/") === true && payload.base64Encoded;
}

export function dataUrlForImage(payload: BodyPayload): string | null {
  if (!isImagePayload(payload) || payload.contentType == null) return null;
  return `data:${payload.contentType};base64,${payload.rawText.replace(/\s+/gu, "")}`;
}

export function bodyMetadata(payload: BodyPayload): string | null {
  const parts: string[] = [];
  if (payload.capturedBytes > 0) {
    parts.push(`Captured ${formatBytes(payload.capturedBytes)}`);
    if (payload.totalBytes != null && payload.totalBytes >= 0) parts.push(`of ${formatBytes(payload.totalBytes)}`);
  } else if (payload.totalBytes != null && payload.totalBytes >= 0) {
    parts.push(`Total ${formatBytes(payload.totalBytes)}`);
  }
  parts.push("(complete)");
  return parts.join(" ");
}

export function prettyJsonOrNull(text: string | null | undefined): string | null {
  if (text == null || text.trim().length === 0) return null;
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return null;
  }
}

export function parseJsonNode(text: string, rootKey = "root"): JsonNode | null {
  try {
    return valueToNode(JSON.parse(text), rootKey, "$", true);
  } catch {
    return null;
  }
}

export function formatBytes(value: number): string {
  if (value < 1000) return `${value} B`;
  if (value < 1000 * 1000) return `${(value / 1000).toFixed(1)} KB`;
  if (value < 1000 * 1000 * 1000) return `${(value / (1000 * 1000)).toFixed(1)} MB`;
  return `${(value / (1000 * 1000 * 1000)).toFixed(1)} GB`;
}

function valueToNode(value: unknown, label: string, key: string, isRoot = false): JsonNode {
  if (Array.isArray(value)) {
    return {
      key,
      label: isRoot ? "[]" : label,
      valuePreview: `${value.length} items`,
      type: "array",
      children: value.map((child, index) => valueToNode(child, `${index}`, `${key}.${index}`))
    };
  }
  if (value != null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>);
    return {
      key,
      label: isRoot ? "{}" : label,
      valuePreview: `${entries.length} fields`,
      type: "object",
      children: entries.map(([childKey, childValue]) => valueToNode(childValue, childKey, `${key}.${escapeKey(childKey)}`))
    };
  }
  return {
    key,
    label,
    valuePreview: primitivePreview(value),
    type: "primitive",
    children: []
  };
}

function primitivePreview(value: unknown): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (value == null) return "null";
  return String(value);
}

function escapeKey(key: string): string {
  return key.replace(/\./gu, "\\.");
}

function isLikelyJson(text: string, contentType: string | null): boolean {
  if (contentType?.includes("json") === true) return true;
  const first = text.trim().at(0);
  return first === "{" || first === "[";
}

function bodyByteLength(value: string, base64Encoded: boolean): number {
  if (!base64Encoded) return new TextEncoder().encode(value).byteLength;
  try {
    return atob(value.replace(/\s+/gu, "")).length;
  } catch {
    return new TextEncoder().encode(value).byteLength;
  }
}
