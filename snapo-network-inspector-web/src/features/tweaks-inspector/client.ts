import type {
  InvokeTweakActionInput,
  StreamStarted,
  TweakList,
  TweakStreamEvent,
  TweakUpdates,
  UpdateTweaksInput
} from "../../network/bridge-types";
import { host } from "../../host";
import { openInspectorLink } from "../../network/client";

export interface TweaksClient {
  listTweaks(): Promise<TweakList>;
  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates>;
  invokeTweakAction(input: InvokeTweakActionInput): Promise<void>;
  startTweakStream(onError?: (error: Error) => void): Promise<StreamStarted>;
  stopTweakStream(streamId: string): Promise<void>;
  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void;
  openExternal(url: string): Promise<void>;
  dispose(): void;
}

export function createTweaksClient(): TweaksClient {
  return new BrowserTweaksClient();
}

class BrowserTweaksClient implements TweaksClient {
  private streams = new Map<string, (error?: Error) => void>();
  private listeners = new Set<(event: TweakStreamEvent) => void>();
  private requests = new Set<AbortController>();
  private disconnected = () => this.revokeConnection();

  constructor() {
    host.addEventListener("connection", this.disconnected);
  }
  dispose(): void {
    host.removeEventListener("connection", this.disconnected);
    this.revokeConnection();
  }

  private async request<T>(path: string, method = "GET", body?: unknown): Promise<T> {
    if (!host.connected || !host.baseURL) throw new Error("Inspector is disconnected.");
    const controller = new AbortController();
    this.requests.add(controller);
    try {
      const response = await fetch(new URL(path, host.baseURL), {
        method,
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(30_000)]),
        headers: body === undefined ? undefined : { "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: "error",
        cache: "no-store"
      });
      if (!response.ok) {
        const error = (await response.json().catch(() => null)) as { error?: string } | null;
        throw new Error(error?.error ?? `Inspector request failed (${response.status}).`);
      }
      return (await response.json()) as T;
    } finally {
      this.requests.delete(controller);
    }
  }

  private revokeConnection(): void {
    for (const request of this.requests) request.abort();
    this.requests.clear();
    for (const close of this.streams.values()) close();
    this.streams.clear();
  }
  listTweaks(): Promise<TweakList> {
    return this.request("tweaks");
  }
  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates> {
    return this.request("tweaks", "PATCH", { values: input.values });
  }
  async invokeTweakAction(input: InvokeTweakActionInput): Promise<void> {
    await this.request("tweaks/action", "POST", { name: input.name });
  }

  async startTweakStream(onError?: (error: Error) => void): Promise<StreamStarted> {
    if (!host.connected || !host.baseURL) throw new Error("Inspector is disconnected.");
    const streamId = crypto.randomUUID();
    const stream = new EventSource(new URL("tweaks/events", host.baseURL));
    return new Promise((resolve, reject) => {
      let opened = false;
      const close = (error?: Error) => {
        if (this.streams.get(streamId) !== close) return;
        this.streams.delete(streamId);
        clearTimeout(timeout);
        stream.removeEventListener("open", open);
        stream.removeEventListener("error", fail);
        stream.removeEventListener("tweaks", receive);
        stream.close();
        if (!opened) reject(error ?? new Error("Inspector is disconnected."));
        else if (error) onError?.(error);
      };
      const open = () => {
        opened = true;
        clearTimeout(timeout);
        resolve({ streamId });
      };
      const fail = () => close(new Error("Tweaks event stream disconnected."));
      const receive = (event: Event) => {
        if (this.streams.get(streamId) !== close) return;
        try {
          const list = JSON.parse((event as MessageEvent<string>).data) as TweakList;
          for (const callback of this.listeners) callback({ ...list, streamId });
        } catch {
          // Retain the previous values when a snapshot is invalid.
        }
      };
      const timeout = setTimeout(() => close(new Error("Tweaks event stream connection timed out.")), 5_000);
      this.streams.set(streamId, close);
      stream.addEventListener("open", open);
      stream.addEventListener("error", fail);
      stream.addEventListener("tweaks", receive);
    });
  }
  async stopTweakStream(streamId: string): Promise<void> {
    this.streams.get(streamId)?.();
  }
  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }
  async openExternal(url: string): Promise<void> {
    openInspectorLink(url);
  }
}
