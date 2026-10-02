import type { Header } from "./cdp";

export interface CapturedRequestBody {
  body: string;
  headers: Header[];
  encoding?: string | null;
}

export type DecodedBody =
  { kind: "text"; text: string } | { kind: "binary"; byteLength: number } | { kind: "unavailable" };

const maxDecodedBytes = 8 * 1024 * 1024;

export function hasGzipContentEncoding(headers: Header[]): boolean {
  return headers
    .filter((header) => header.name.toLowerCase() === "content-encoding")
    .flatMap((header) => header.value.split(/[,\n]/u))
    .some((token) => ["gzip", "x-gzip"].includes(token.split(";")[0].trim().toLowerCase()));
}

export async function decodeRequestBody(input: CapturedRequestBody, signal?: AbortSignal): Promise<DecodedBody> {
  signal?.throwIfAborted();
  if (input.encoding?.toLowerCase() !== "base64") return { kind: "text", text: input.body };
  if (
    !hasGzipContentEncoding(input.headers) ||
    input.body.length > maxDecodedBytes * 2 ||
    typeof DecompressionStream === "undefined"
  )
    return { kind: "unavailable" };
  try {
    const bytes = Uint8Array.from(atob(input.body.replace(/\s+/gu, "")), (char) => char.charCodeAt(0));
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")).getReader();
    const chunks: Uint8Array<ArrayBuffer>[] = [];
    let length = 0;
    try {
      while (true) {
        signal?.throwIfAborted();
        const { value, done } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > maxDecodedBytes) return { kind: "unavailable" };
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    const decoded = await new Blob(chunks).arrayBuffer();
    signal?.throwIfAborted();
    try {
      return { kind: "text", text: textDecoder(input.headers).decode(decoded) };
    } catch {
      return { kind: "binary", byteLength: length };
    }
  } catch {
    signal?.throwIfAborted();
    return { kind: "unavailable" };
  }
}

function textDecoder(headers: Header[]): TextDecoder {
  const contentType = headers.find((header) => header.name.toLowerCase() === "content-type")?.value;
  const charset = contentType?.match(/;\s*charset\s*=\s*(?:"([^"\r\n]*)"|([^;\s]*))/iu);
  try {
    return new TextDecoder(charset?.[1] ?? charset?.[2] ?? "utf-8", { fatal: true });
  } catch {
    return new TextDecoder("utf-8", { fatal: true });
  }
}
