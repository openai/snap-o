import type { InvokeTweakActionInput, TweakList, TweakUpdates, UpdateTweaksInput } from "../../types";
import { host, type ToolConnection } from "@snap-o/tool-host";

export interface TweaksClient {
  listTweaks(): Promise<TweakList>;
  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates>;
  invokeTweakAction(input: InvokeTweakActionInput): Promise<void>;
  subscribeTweaks(
    connection: ToolConnection,
    onSnapshot: (snapshot: TweakList) => void,
    onError: (error: Error) => void
  ): () => void;
  openExternal(url: string): Promise<void>;
  dispose(): void;
}

export function createTweaksClient(): TweaksClient {
  return new BrowserTweaksClient();
}

class BrowserTweaksClient implements TweaksClient {
  private subscriptions = new Set<() => void>();
  private readonly lifetime = new AbortController();
  private readonly unsubscribe = host.onConnection(() => () => {
    for (const close of this.subscriptions) close();
  });

  dispose(): void {
    this.unsubscribe();
    this.lifetime.abort();
  }

  private async request<T>(path: string, method = "GET", body?: unknown): Promise<T> {
    const current = host.connection;
    if (!current || this.lifetime.signal.aborted) throw new Error("Tool is disconnected.");
    const response = await fetch(new URL(path, current.baseURL), {
      method,
      signal: AbortSignal.any([current.signal, this.lifetime.signal, AbortSignal.timeout(30_000)]),
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: "error",
      cache: "no-store"
    });
    if (!response.ok) {
      const error = (await response.json().catch(() => null)) as { error?: string } | null;
      throw new Error(error?.error ?? `Tool request failed (${response.status}).`);
    }
    return (await response.json()) as T;
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

  subscribeTweaks(
    connection: ToolConnection,
    onSnapshot: (snapshot: TweakList) => void,
    onError: (error: Error) => void
  ): () => void {
    if (connection.signal.aborted || this.lifetime.signal.aborted) throw new Error("Tool is disconnected.");
    const stream = new EventSource(new URL("tweaks/events", connection.baseURL));
    let closed = false;
    const close = () => {
      if (closed) return;
      closed = true;
      this.subscriptions.delete(close);
      clearTimeout(timeout);
      stream.removeEventListener("error", fail);
      stream.removeEventListener("tweaks", receive);
      stream.close();
    };
    const fail = () => {
      if (closed) return;
      close();
      onError(new Error("Tweaks event stream disconnected."));
    };
    const receive = (event: Event) => {
      if (closed || connection.signal.aborted) return;
      let snapshot: TweakList;
      try {
        snapshot = JSON.parse((event as MessageEvent<string>).data) as TweakList;
        if (!Array.isArray(snapshot?.tweaks)) throw new Error("Invalid Tweaks snapshot.");
      } catch {
        close();
        onError(new Error("Invalid Tweaks snapshot."));
        return;
      }
      clearTimeout(timeout);
      onSnapshot(snapshot);
    };
    // Opening the HTTP response is not enough: editing needs a current snapshot.
    const timeout = setTimeout(() => {
      close();
      onError(new Error("Tweaks snapshot timed out."));
    }, 5_000);
    this.subscriptions.add(close);
    stream.addEventListener("error", fail);
    stream.addEventListener("tweaks", receive);
    return close;
  }
  async openExternal(url: string): Promise<void> {
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.click();
  }
}
