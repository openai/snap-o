import type { RequestBodies } from "./bridge-types";

// The selected request is pinned so its detail view stays stable. All other hydrated bodies
// share this LRU budget; exports hydrate missing bodies only for the duration of the export.
export const hydratedBodyRetentionLimitBytes = 16 * 1024 * 1024;

interface CacheEntry {
  bodies: RequestBodies;
  estimatedBytes: number;
}

export class RequestBodyCache {
  private readonly entries = new Map<string, CacheEntry>();
  private protectedRecordKey: string | null = null;
  private retainedBytes = 0;

  constructor(private readonly maximumBytes = hydratedBodyRetentionLimitBytes) {
    if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1) {
      throw new Error("Body retention budget must be a positive integer");
    }
  }

  get retainedByteCount(): number {
    return this.retainedBytes;
  }

  peek(recordKey: string): RequestBodies | null {
    return this.entries.get(recordKey)?.bodies ?? null;
  }

  select(recordKey: string | null): string[] {
    this.protectedRecordKey = recordKey;
    if (recordKey != null) this.touch(recordKey);
    return this.evictOverBudget();
  }

  put(recordKey: string, bodies: RequestBodies): string[] {
    const existing = this.entries.get(recordKey);
    if (existing != null) this.retainedBytes -= existing.estimatedBytes;

    const merged = mergeBodies(existing?.bodies, bodies);
    const entry = { bodies: merged, estimatedBytes: estimatedBodyBytes(merged) };
    this.entries.delete(recordKey);
    this.entries.set(recordKey, entry);
    this.retainedBytes += entry.estimatedBytes;
    return this.evictOverBudget();
  }

  retainRecords(recordKeys: Set<string>): string[] {
    return this.evict([...this.entries.keys()].filter((key) => !recordKeys.has(key)));
  }

  private touch(recordKey: string): void {
    const entry = this.entries.get(recordKey);
    if (entry == null) return;
    this.entries.delete(recordKey);
    this.entries.set(recordKey, entry);
  }

  private evictOverBudget(): string[] {
    const evicted: string[] = [];
    for (const key of this.entries.keys()) {
      if (this.retainedBytes <= this.maximumBytes) break;
      if (key === this.protectedRecordKey) continue;
      evicted.push(key);
      const entry = this.entries.get(key);
      if (entry != null) this.retainedBytes -= entry.estimatedBytes;
      this.entries.delete(key);
    }
    return evicted;
  }

  private evict(recordKeys: string[]): string[] {
    const evicted: string[] = [];
    for (const key of recordKeys) {
      const entry = this.entries.get(key);
      if (entry == null) continue;
      this.entries.delete(key);
      this.retainedBytes -= entry.estimatedBytes;
      evicted.push(key);
    }
    return evicted;
  }
}

function mergeBodies(existing: RequestBodies | undefined, incoming: RequestBodies): RequestBodies {
  return {
    requestId: incoming.requestId,
    requestBody: incoming.requestBody ?? existing?.requestBody,
    responseBody: incoming.responseBody ?? existing?.responseBody,
    responseBodyBase64Encoded: incoming.responseBodyBase64Encoded ?? existing?.responseBodyBase64Encoded,
    responseBodyLoadCompleted: incoming.responseBodyLoadCompleted ?? existing?.responseBodyLoadCompleted,
    responseBodyLoadError:
      incoming.responseBodyLoadError !== undefined ? incoming.responseBodyLoadError : existing?.responseBodyLoadError,
    originalResponseBody: incoming.originalResponseBody ?? existing?.originalResponseBody,
    originalResponseBodyBase64Encoded:
      incoming.originalResponseBodyBase64Encoded ?? existing?.originalResponseBodyBase64Encoded,
    originalResponseBodyLoadCompleted:
      incoming.originalResponseBodyLoadCompleted ?? existing?.originalResponseBodyLoadCompleted,
    originalResponseBodyLoadError:
      incoming.originalResponseBodyLoadError !== undefined
        ? incoming.originalResponseBodyLoadError
        : existing?.originalResponseBodyLoadError
  };
}

function estimatedBodyBytes(bodies: RequestBodies): number {
  return (
    estimatedStringStorageBytes(bodies.requestBody) +
    estimatedStringStorageBytes(bodies.responseBody) +
    estimatedStringStorageBytes(bodies.originalResponseBody)
  );
}

export function estimatedStringStorageBytes(value: string | null | undefined): number {
  // JavaScript strings can require two bytes per UTF-16 code unit. Use that upper-bound estimate
  // so the cache budget reflects renderer memory rather than wire encoding.
  return value == null ? 0 : value.length * 2;
}
