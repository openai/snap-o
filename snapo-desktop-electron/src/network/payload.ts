import type { Header } from "./cdp";

export interface JsonNode {
  key: string;
  label: string;
  rawValue: unknown;
  type: "object" | "array" | "string" | "number" | "boolean" | "null";
  children: JsonNode[];
}

export type JsonFormat = "none" | "single" | "stream" | "invalid";

export interface BodyPayload {
  rawText: string;
  displayText: string;
  prettyText: string | null;
  jsonFormat: JsonFormat;
  contentType: string | null;
  encoding: string | null;
  capturedBytes: number;
  totalBytes: number | null;
  base64Encoded: boolean;
}

export function makeBodyPayload(input: {
  body: string | null | undefined;
  displayText?: string | null;
  headers: Header[];
  encoding?: string | null;
  base64Encoded?: boolean | null;
  totalBytes?: number | null;
}): BodyPayload | null {
  if (input.body == null || input.body.length === 0) return null;
  const contentType = contentTypeFromHeaders(input.headers);
  const base64Encoded = input.base64Encoded === true || input.encoding?.toLowerCase() === "base64";
  const rawText = input.body;
  const displayText = input.displayText ?? rawText;
  const json = base64Encoded && displayText === rawText ? noJson : inspectJson(displayText, contentType);
  return {
    rawText,
    displayText,
    prettyText: json.prettyText,
    jsonFormat: json.format,
    contentType,
    encoding: base64Encoded ? "base64" : (input.encoding ?? null),
    capturedBytes: bodyByteLength(rawText, base64Encoded),
    totalBytes: input.totalBytes ?? null,
    base64Encoded
  };
}

export async function decodeRequestBodyForDisplay(input: {
  body: string;
  headers: Header[];
  encoding?: string | null;
}): Promise<string> {
  if (input.encoding?.toLowerCase() !== "base64") return input.body;
  if (!hasGzipContentEncoding(headerValue(input.headers, "content-encoding"))) return input.body;

  const bytes = decodeBase64Bytes(input.body);
  if (bytes == null || typeof DecompressionStream === "undefined") return input.body;

  try {
    const decompressed = await decompressGzip(bytes);
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(decompressed);
    } catch {
      return `Binary payload after gzip decompression (${formatBytes(decompressed.byteLength)}). Raw payload is shown below as captured.\n\n${input.body}`;
    }
  } catch {
    return input.body;
  }
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
    if (payload.totalBytes != null && payload.totalBytes > payload.capturedBytes) {
      parts.push(`of ${formatBytes(payload.totalBytes)}`);
    }
  } else if (payload.totalBytes != null && payload.totalBytes >= 0) {
    parts.push(`Total ${formatBytes(payload.totalBytes)}`);
  }
  return parts.length === 0 ? null : parts.join(" ");
}

function headerValue(headers: Header[], name: string): string | null {
  return headers.find((header) => header.name.toLowerCase() === name)?.value ?? null;
}

function hasGzipContentEncoding(value: string | null): boolean {
  if (value == null || value.trim().length === 0) return false;
  return value
    .split(/[,\n]/u)
    .map((token) => token.split(";")[0].trim().toLowerCase())
    .some((token) => token === "gzip" || token === "x-gzip");
}

async function decompressGzip(bytes: Uint8Array): Promise<Uint8Array> {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const stream = new Blob([copy.buffer]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export function prettyJsonOrNull(text: string | null | undefined): string | null {
  if (text == null || text.trim().length === 0) return null;
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return null;
  }
}

interface JsonInspection {
  format: JsonFormat;
  prettyText: string | null;
}

const noJson: JsonInspection = {
  format: "none",
  prettyText: null
};

function inspectJson(text: string, contentType: string | null): JsonInspection {
  const prettyText = prettyJsonOrNull(text);
  if (prettyText != null) return { format: "single", prettyText };

  const prettyStream = prettyJsonStreamOrNull(text);
  if (prettyStream != null) return { format: "stream", prettyText: prettyStream };

  return isLikelyJson(text, contentType) ? { format: "invalid", prettyText: null } : noJson;
}

function prettyJsonStreamOrNull(text: string): string | null {
  const documents = text
    .split(/\r?\n/u)
    .map((document) => document.trim())
    .filter((document) => document.length > 0);
  if (documents.length < 2) return null;

  const prettyDocuments: string[] = [];
  for (const document of documents) {
    const prettyDocument = prettyJsonOrNull(document);
    if (prettyDocument == null) return null;
    prettyDocuments.push(prettyDocument);
  }
  return prettyDocuments.join("\n");
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
      label: isRoot ? "" : label,
      rawValue: value,
      type: "array",
      children: value.map((child, index) => valueToNode(child, `[${index}]`, `${key}.${index}`))
    };
  }
  if (value != null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>);
    return {
      key,
      label: isRoot ? "" : label,
      rawValue: value,
      type: "object",
      children: entries.map(([childKey, childValue]) =>
        valueToNode(childValue, childKey, `${key}.${escapeKey(childKey)}`)
      )
    };
  }
  const type = primitiveType(value);
  return {
    key,
    label,
    rawValue: value,
    type,
    children: []
  };
}

function primitiveType(value: unknown): JsonNode["type"] {
  if (typeof value === "string") return "string";
  if (typeof value === "number") return "number";
  if (typeof value === "boolean") return "boolean";
  return "null";
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
