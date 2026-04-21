import type {
  LoadBodiesInput,
  RequestBodies,
  SnapONetworkBridge,
  SnapOServer,
  StartStreamInput,
  StreamEvent,
  StreamStarted,
  StreamStatus
} from "./bridge-types";

export interface NetworkClient {
  listServers(): Promise<SnapOServer[]>;
  loadBodies(input: LoadBodiesInput): Promise<RequestBodies>;
  startStream(input: StartStreamInput): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onEvent(callback: (event: StreamEvent) => void): () => void;
  onStatus(callback: (status: StreamStatus) => void): () => void;
  openExternal(url: string): Promise<void>;
}

export function createNetworkClient(): NetworkClient {
  if (window.snapONetwork != null) {
    return new ElectronNetworkClient(window.snapONetwork);
  }
  return new HttpNetworkClient();
}

class ElectronNetworkClient implements NetworkClient {
  constructor(private readonly bridge: SnapONetworkBridge) {}

  listServers(): Promise<SnapOServer[]> {
    return this.bridge.listServers();
  }

  loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    return this.bridge.loadBodies(input);
  }

  startStream(input: StartStreamInput): Promise<StreamStarted> {
    return this.bridge.startStream(input);
  }

  stopStream(streamId: string): Promise<void> {
    return this.bridge.stopStream(streamId);
  }

  onEvent(callback: (event: StreamEvent) => void): () => void {
    return this.bridge.onEvent(callback);
  }

  onStatus(callback: (status: StreamStatus) => void): () => void {
    return this.bridge.onStatus(callback);
  }

  openExternal(url: string): Promise<void> {
    return this.bridge.openExternal(url);
  }
}

class HttpNetworkClient implements NetworkClient {
  private eventSource: EventSource | null = null;
  private statusCallbacks = new Set<(status: StreamStatus) => void>();
  private eventCallbacks = new Set<(event: StreamEvent) => void>();

  async listServers(): Promise<SnapOServer[]> {
    return fetchJson("/api/network/servers");
  }

  async loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    return fetchJson("/api/network/bodies", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input)
    });
  }

  async startStream(input: StartStreamInput): Promise<StreamStarted> {
    const started = await fetchJson<StreamStarted>("/api/network/streams", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input)
    });
    this.ensureEventSource();
    return started;
  }

  async stopStream(streamId: string): Promise<void> {
    await fetch(`/api/network/streams/${encodeURIComponent(streamId)}`, { method: "DELETE" });
  }

  onEvent(callback: (event: StreamEvent) => void): () => void {
    this.eventCallbacks.add(callback);
    this.ensureEventSource();
    return () => this.eventCallbacks.delete(callback);
  }

  onStatus(callback: (status: StreamStatus) => void): () => void {
    this.statusCallbacks.add(callback);
    this.ensureEventSource();
    return () => this.statusCallbacks.delete(callback);
  }

  async openExternal(url: string): Promise<void> {
    window.open(url, "_blank", "noopener,noreferrer");
  }

  private ensureEventSource(): void {
    if (this.eventSource != null) return;
    this.eventSource = new EventSource("/api/network/events");
    this.eventSource.addEventListener("event", (event) => {
      const payload = JSON.parse(event.data) as StreamEvent;
      for (const callback of this.eventCallbacks) callback(payload);
    });
    this.eventSource.addEventListener("status", (event) => {
      const payload = JSON.parse(event.data) as StreamStatus;
      for (const callback of this.statusCallbacks) callback(payload);
    });
  }
}

async function fetchJson<T>(input: RequestInfo | URL, init?: RequestInit): Promise<T> {
  const response = await fetch(input, init);
  if (!response.ok) {
    throw new Error(`Request failed with ${response.status}`);
  }
  return response.json() as Promise<T>;
}

