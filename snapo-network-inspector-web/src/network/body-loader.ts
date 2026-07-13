import type { LoadBodiesInput, RequestBodies } from "./bridge-types";

export const bodyLoadPriority = {
  selected: 0,
  visible: 1,
  background: 2
} as const;

export type BodyLoadPriority = (typeof bodyLoadPriority)[keyof typeof bodyLoadPriority];

export interface BodyLoadJob {
  key: string;
  recordKey: string;
  input: LoadBodiesInput;
  priority: BodyLoadPriority;
}

interface BodyLoadEntry extends BodyLoadJob {
  order: number;
  status: "queued" | "running" | "complete";
  cancelled: boolean;
}

type LoadBodies = (input: LoadBodiesInput) => Promise<RequestBodies>;
type DidLoadBodies = (recordKey: string, bodies: RequestBodies) => void;

export class RequestBodyLoader {
  private readonly entries = new Map<string, BodyLoadEntry>();
  private retainedRecordKeys = new Set<string>();
  private runningCount = 0;
  private nextOrder = 0;
  private disposed = false;

  constructor(
    private readonly loadBodies: LoadBodies,
    private readonly didLoadBodies: DidLoadBodies,
    private readonly concurrency = 3
  ) {
    if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
      throw new Error("Body loader concurrency must be a positive integer");
    }
  }

  schedule(jobs: BodyLoadJob[]): void {
    if (this.disposed) return;

    for (const job of jobs) {
      const existing = this.entries.get(job.key);
      if (existing != null) {
        if (existing.status === "queued" && job.priority < existing.priority) {
          existing.priority = job.priority;
        }
        continue;
      }

      this.entries.set(job.key, {
        ...job,
        order: this.nextOrder,
        status: "queued",
        cancelled: false
      });
      this.nextOrder += 1;
    }

    this.drain();
  }

  retainRecords(recordKeys: Set<string>): void {
    this.retainedRecordKeys = recordKeys;
    for (const [key, entry] of this.entries) {
      if (!recordKeys.has(entry.recordKey)) {
        entry.cancelled = true;
        this.entries.delete(key);
      }
    }
  }

  forgetRecords(recordKeys: Iterable<string>): void {
    for (const recordKey of recordKeys) {
      for (const [key, entry] of this.entries) {
        if (entry.recordKey !== recordKey) continue;
        entry.cancelled = true;
        this.entries.delete(key);
      }
    }
  }

  dispose(): void {
    this.disposed = true;
    for (const entry of this.entries.values()) entry.cancelled = true;
    this.entries.clear();
  }

  private drain(): void {
    while (!this.disposed && this.runningCount < this.concurrency) {
      const entry = this.nextQueuedEntry();
      if (entry == null) return;

      entry.status = "running";
      this.runningCount += 1;
      void this.loadBodies(entry.input)
        .then((bodies) => {
          if (!this.disposed && !entry.cancelled && this.retainedRecordKeys.has(entry.recordKey)) {
            this.didLoadBodies(entry.recordKey, {
              ...bodies,
              ...(entry.input.includeResponseBody ? { responseBodyLoadCompleted: true } : {})
            });
          }
        })
        .catch(() => {
          if (
            entry.input.includeResponseBody &&
            !this.disposed &&
            !entry.cancelled &&
            this.retainedRecordKeys.has(entry.recordKey)
          ) {
            this.didLoadBodies(entry.recordKey, {
              requestId: entry.input.requestId,
              responseBodyLoadCompleted: true
            });
          }
        })
        .finally(() => {
          this.runningCount -= 1;
          if (this.entries.get(entry.key) !== entry) {
            this.drain();
            return;
          }
          if (this.disposed || entry.cancelled || !this.retainedRecordKeys.has(entry.recordKey)) {
            this.entries.delete(entry.key);
          } else {
            entry.status = "complete";
          }
          this.drain();
        });
    }
  }

  private nextQueuedEntry(): BodyLoadEntry | null {
    let next: BodyLoadEntry | null = null;
    for (const entry of this.entries.values()) {
      if (entry.status !== "queued") continue;
      if (
        next == null ||
        entry.priority < next.priority ||
        (entry.priority === next.priority && entry.order < next.order)
      ) {
        next = entry;
      }
    }
    return next;
  }
}
