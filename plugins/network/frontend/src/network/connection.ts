import type { PluginMetadata } from "../features/app-tool/usePluginMetadata";
import { readText } from "../http";
import type { CdpMessage, LoadBodiesInput, RequestBodies, StreamEvent, StreamStatus } from "./bridge-types";
import { supportedProtocolVersion } from "../features/network-tool/lib/protocol";

const maximumRecordBytes = 16 * 1024 * 1024;
const encoder = new TextEncoder();

interface ConnectionTransport {
  fetch: typeof fetch;
  eventSource: (url: string) => EventSource;
}

export class NetworkConnection {
  readonly id = crypto.randomUUID();
  private readonly abort = new AbortController();
  private stream: EventSource | undefined;
  private readonly processId: string;
  private closed = false;
  private rejectOpening: ((error: Error) => void) | undefined;
  private replaying = true;
  private watermark = 0;
  private buffered: CdpMessage[] = [];
  private bufferedBytes = 0;

  constructor(
    private baseURL: string,
    private metadata: PluginMetadata,
    private onEvent: (event: StreamEvent) => void,
    private onStatus: (status: StreamStatus) => void,
    private transport: ConnectionTransport = {
      fetch: (...args) => fetch(...args),
      eventSource: (url) => new EventSource(url)
    }
  ) {
    this.processId = metadata.processIdentity;
  }

  async start(): Promise<void> {
    try {
      if (this.metadata.protocolVersion !== supportedProtocolVersion) {
        throw new Error("This app uses an unsupported Network Tool protocol.");
      }
      await this.openEvents();
      await this.history();
      this.checkOpen();
      this.replaying = false;
      for (const message of this.buffered) this.publishLive(message);
      this.buffered = [];
      this.bufferedBytes = 0;
    } catch (error) {
      this.close(error instanceof Error ? error : new Error("Tool connection failed."));
      throw error;
    }
  }

  close(error = new Error("Tool connection ended.")): void {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    this.rejectOpening?.(error);
    this.rejectOpening = undefined;
    this.stream?.close();
    this.buffered = [];
    this.bufferedBytes = 0;
    this.onStatus({ streamId: this.id, state: "exit", message: error.message });
  }

  async loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    this.checkOpen();
    if (input.processId !== this.processId) {
      throw new Error("The request belongs to an earlier app process.");
    }
    const result: RequestBodies = { requestId: input.requestId };
    const path = `network/requests/${encodeURIComponent(input.requestId)}`;
    await Promise.all([
      input.includeRequestBody !== false
        ? this.json(`${path}/request-body`, maximumRecordBytes, true).then((body) => {
            if (typeof body?.postData === "string") result.requestBody = body.postData;
          })
        : undefined,
      input.includeResponseBody !== false
        ? this.json(`${path}/response-body`, maximumRecordBytes, true).then((body) => {
            if (typeof body?.body === "string") {
              result.responseBody = body.body;
              result.responseBodyBase64Encoded = body.base64Encoded === true;
              result.responseBodyLoadCompleted = true;
            } else result.responseBodyLoadError = "unavailable";
          })
        : undefined
    ]);
    this.checkOpen();
    return result;
  }

  private url(path: string): string {
    return new URL(path, this.baseURL).href;
  }

  private checkOpen(): void {
    if (this.closed) throw new Error("Tool is disconnected.");
  }

  private async response(path: string, accept = "application/json"): Promise<Response> {
    this.checkOpen();
    return this.transport.fetch(this.url(path), {
      headers: { Accept: accept },
      signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(30_000)]),
      cache: "no-store",
      redirect: "error"
    });
  }

  private async json(path: string, limit: number, allowMissing = false): Promise<Record<string, unknown> | null> {
    const response = await this.response(path);
    if (allowMissing && response.status === 404) {
      await response.body?.cancel();
      return null;
    }
    if (!response.ok || !response.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) {
      await response.body?.cancel();
      throw new Error(`Tool request failed (${response.status}).`);
    }
    const text = await readText(response, limit);
    this.checkOpen();
    const result: unknown = JSON.parse(text);
    if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("Invalid tool response.");
    return result as Record<string, unknown>;
  }

  private openEvents(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.rejectOpening = reject;
      const stream = this.transport.eventSource(this.url("network"));
      const timeout = setTimeout(() => this.close(new Error("Tool connection timed out.")), 5_000);
      this.stream = stream;
      const opened = () => {
        clearTimeout(timeout);
        this.rejectOpening = undefined;
        if (!this.closed) resolve();
      };
      stream.addEventListener("open", opened, { once: true });
      stream.addEventListener("error", () => {
        clearTimeout(timeout);
        // EventSource retries cannot recover missed events. Start a new snapshot instead.
        this.close(new Error("Tool connection ended."));
      });
      stream.addEventListener("message", (event) => {
        if (this.closed) return;
        try {
          const bytes = encoder.encode(event.data).byteLength;
          const message = parseRecord(event.data, bytes);
          if (event.lastEventId !== String(message.snapoSequence)) throw new Error("Invalid tool event sequence.");
          if (this.replaying) {
            if (this.buffered.length >= 4096 || this.bufferedBytes + bytes > 32 * 1024 * 1024) {
              throw new Error("Tool history could not keep up with live events.");
            }
            this.buffered.push(message);
            this.bufferedBytes += bytes;
          } else this.publishLive(message);
        } catch (error) {
          this.close(error instanceof Error ? error : new Error("Invalid tool event."));
        }
      });
      this.abort.signal.addEventListener("abort", () => clearTimeout(timeout), { once: true });
    });
  }

  private async history(): Promise<void> {
    const response = await this.response("network", "application/x-ndjson");
    const watermark = response.headers.get("SnapO-Sequence");
    if (
      !response.ok ||
      !response.headers.get("Content-Type")?.toLowerCase().startsWith("application/x-ndjson") ||
      !watermark ||
      !/^\d+$/.test(watermark) ||
      !Number.isSafeInteger(Number(watermark)) ||
      !response.body
    ) {
      await response.body?.cancel();
      throw new Error("Invalid tool history response.");
    }
    this.watermark = Number(watermark);
    const reader = response.body.getReader();
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let line = "";
    let length = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        this.checkOpen();
        if (done) break;
        let start = 0;
        for (let index = 0; index < value.length; index++) {
          if (value[index] !== 10) continue;
          length += index - start;
          if (length > maximumRecordBytes) throw new Error("Tool history record is too large.");
          line += decoder.decode(value.subarray(start, index));
          const message = parseRecord(line, length);
          if (message.snapoSequence! > this.watermark) throw new Error("Invalid tool history sequence.");
          this.publish(message);
          line = "";
          length = 0;
          start = index + 1;
        }
        length += value.length - start;
        if (length > maximumRecordBytes) throw new Error("Tool history record is too large.");
        line += decoder.decode(value.subarray(start), { stream: true });
      }
      line += decoder.decode();
      if (length || line) throw new Error("Tool history ended during a record.");
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  }

  private publishLive(message: CdpMessage): void {
    if (message.snapoSequence! > this.watermark) this.publish(message);
  }

  private publish(message: CdpMessage): void {
    this.checkOpen();
    this.onEvent({ streamId: this.id, processId: this.processId, message });
  }
}

function parseRecord(text: string, bytes: number): CdpMessage {
  if (bytes > maximumRecordBytes) throw new Error("Tool record is too large.");
  const message = JSON.parse(text) as CdpMessage;
  if (
    !message ||
    typeof message !== "object" ||
    !message.method?.startsWith("Network.") ||
    !message.params ||
    typeof message.params !== "object" ||
    Array.isArray(message.params) ||
    !Number.isSafeInteger(message.snapoSequence) ||
    message.snapoSequence! < 0 ||
    "id" in message ||
    "result" in message ||
    "error" in message
  )
    throw new Error("Invalid tool record.");
  return message;
}
