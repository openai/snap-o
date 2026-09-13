import type { ToolConnection } from "@snap-o/tool-host";
import type { StreamStarted, StreamClosed } from "./bridge-types";

export type StreamLifecycleState = "starting" | "streaming" | "retrying";

interface StreamLifecycleClient {
  startStream(input: ToolConnection): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onClosed(callback: (event: StreamClosed) => void): () => void;
}

interface StreamControllerOptions {
  retryDelaysMs?: readonly number[];
  stableAfterMs?: number;
  now?: () => number;
}

const defaultRetryDelaysMs = [250, 500, 1_000, 2_000, 4_000, 5_000] as const;
const defaultStableAfterMs = 10_000;
const maximumBufferedClosedStreams = 32;

export class NetworkStreamController {
  private readonly retryDelaysMs: readonly number[];
  private readonly stableAfterMs: number;
  private readonly now: () => number;
  private readonly closedStreams = new Set<string>();
  private activeStreamId: string | null = null;
  private activeSince: number | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private unsubscribeClosed: (() => void) | null = null;
  private retryIndex = 0;
  private attemptGeneration = 0;
  private started = false;
  private disposed = false;

  constructor(
    private readonly client: StreamLifecycleClient,
    private readonly input: ToolConnection,
    private readonly didChangeState: (state: StreamLifecycleState) => void,
    options: StreamControllerOptions = {}
  ) {
    this.retryDelaysMs = options.retryDelaysMs ?? defaultRetryDelaysMs;
    this.stableAfterMs = options.stableAfterMs ?? defaultStableAfterMs;
    this.now = options.now ?? Date.now;
    if (this.retryDelaysMs.length === 0 || this.retryDelaysMs.some((delay) => delay < 0)) {
      throw new Error("Stream retry delays must contain non-negative values");
    }
  }

  start(): void {
    if (this.started || this.disposed) return;
    this.started = true;
    this.unsubscribeClosed = this.client.onClosed((event) => this.handleClosed(event));
    this.didChangeState("starting");
    this.startAttempt();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.attemptGeneration += 1;
    this.unsubscribeClosed?.();
    this.unsubscribeClosed = null;
    if (this.retryTimer != null) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    const streamId = this.activeStreamId;
    this.activeStreamId = null;
    this.activeSince = null;
    if (streamId != null) void this.client.stopStream(streamId).catch(() => {});
  }

  private startAttempt(): void {
    if (this.disposed) return;
    const generation = ++this.attemptGeneration;
    void this.client
      .startStream(this.input)
      .then((started) => {
        if (this.disposed || generation !== this.attemptGeneration) {
          void this.client.stopStream(started.streamId).catch(() => {});
          return;
        }

        if (this.closedStreams.delete(started.streamId)) {
          this.scheduleRetry();
          return;
        }

        this.activeStreamId = started.streamId;
        this.activeSince = this.now();
        this.didChangeState("streaming");
      })
      .catch(() => {
        if (!this.disposed && generation === this.attemptGeneration) this.scheduleRetry();
      });
  }

  private handleClosed(event: StreamClosed): void {
    if (this.disposed) return;
    if (event.streamId !== this.activeStreamId) {
      this.rememberClosedStream(event.streamId);
      return;
    }

    if (this.activeSince != null && this.now() - this.activeSince >= this.stableAfterMs) {
      this.retryIndex = 0;
    }
    this.activeStreamId = null;
    this.activeSince = null;
    this.scheduleRetry();
  }

  private rememberClosedStream(streamId: string): void {
    this.closedStreams.add(streamId);
    while (this.closedStreams.size > maximumBufferedClosedStreams) {
      const oldest = this.closedStreams.values().next().value as string | undefined;
      if (oldest == null) break;
      this.closedStreams.delete(oldest);
    }
  }

  private scheduleRetry(): void {
    if (this.disposed || this.retryTimer != null) return;
    this.didChangeState("retrying");
    const delayIndex = Math.min(this.retryIndex, this.retryDelaysMs.length - 1);
    const delay = this.retryDelaysMs[delayIndex];
    this.retryIndex = Math.min(this.retryIndex + 1, this.retryDelaysMs.length - 1);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.startAttempt();
    }, delay);
  }
}
