import type {
  DebugInspectorPreset,
  LoadBodiesInput,
  NativeInspectorState,
  RequestBodies,
  SaveFileInput,
  SaveFileResult,
  SnapOServer,
  StartStreamInput,
  StreamEvent,
  StreamStarted,
  StreamStatus
} from "./bridge-types";

export interface NetworkClient {
  readonly usesNativeServerPicker: boolean;
  appVersion(): Promise<string>;
  listServers(): Promise<SnapOServer[]>;
  loadBodies(input: LoadBodiesInput): Promise<RequestBodies>;
  startStream(input: StartStreamInput): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onEvent(callback: (event: StreamEvent) => void): () => void;
  onStatus(callback: (status: StreamStatus) => void): () => void;
  openExternal(url: string): Promise<void>;
  saveFile(input: SaveFileInput): Promise<SaveFileResult>;
  debugInspectorPreset(): Promise<DebugInspectorPreset>;
  onDebugInspectorPreset(callback: (preset: DebugInspectorPreset) => void): () => void;
  selectedDeviceChanged(deviceId: string): void;
  onPreferredDevice(callback: (deviceId: string) => void): () => void;
  nativeInspectorStateChanged(state: NativeInspectorState): void;
  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void;
}

export function createNetworkClient(): NetworkClient {
  if (webKitMessageHandler() != null) return new WebKitNetworkClient();
  return new HttpNetworkClient();
}

interface WebKitMessageHandler {
  postMessage(message: { command: string; payload?: unknown }): Promise<unknown>;
}

function webKitMessageHandler(): WebKitMessageHandler | null {
  const hostWindow = window as Window & {
    webkit?: { messageHandlers?: { snapoNetwork?: WebKitMessageHandler } };
  };
  return hostWindow.webkit?.messageHandlers?.snapoNetwork ?? null;
}

class WebKitNetworkClient implements NetworkClient {
  readonly usesNativeServerPicker = true;

  appVersion(): Promise<string> {
    return this.invoke<string>("appVersion");
  }

  listServers(): Promise<SnapOServer[]> {
    return this.invoke<SnapOServer[]>("listServers");
  }

  loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    return this.invoke<RequestBodies>("loadBodies", input);
  }

  startStream(input: StartStreamInput): Promise<StreamStarted> {
    return this.invoke<StreamStarted>("startStream", input);
  }

  stopStream(streamId: string): Promise<void> {
    return this.invoke<void>("stopStream", { streamId });
  }

  onEvent(callback: (event: StreamEvent) => void): () => void {
    return listenWebKitEvent<StreamEvent>("network:event", callback);
  }

  onStatus(callback: (status: StreamStatus) => void): () => void {
    return listenWebKitEvent<StreamStatus>("network:status", callback);
  }

  openExternal(url: string): Promise<void> {
    return this.invoke<void>("openExternal", { url });
  }

  saveFile(input: SaveFileInput): Promise<SaveFileResult> {
    return this.invoke<SaveFileResult>("saveFile", input);
  }

  debugInspectorPreset(): Promise<DebugInspectorPreset> {
    return this.invoke<DebugInspectorPreset>("debugInspectorPreset");
  }

  onDebugInspectorPreset(callback: (preset: DebugInspectorPreset) => void): () => void {
    return listenWebKitEvent<DebugInspectorPreset>("debug:inspector-preset", callback);
  }

  selectedDeviceChanged(deviceId: string): void {
    void this.invoke<void>("selectedDeviceChanged", { deviceId });
  }

  onPreferredDevice(callback: (deviceId: string) => void): () => void {
    return listenWebKitEvent<string>("network:preferred-device", callback);
  }

  nativeInspectorStateChanged(state: NativeInspectorState): void {
    void this.invoke<void>("inspectorStateChanged", state);
  }

  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void {
    return listenWebKitEvent<StartStreamInput>("network:selected-server", callback);
  }

  private async invoke<T>(command: string, payload?: unknown): Promise<T> {
    const handler = webKitMessageHandler();
    if (handler == null) throw new Error("Snap-O native bridge is unavailable");
    return (await handler.postMessage({ command, payload })) as T;
  }
}

function listenWebKitEvent<T>(eventName: string, callback: (payload: T) => void): () => void {
  const listener = (event: Event) => callback((event as CustomEvent<T>).detail);
  window.addEventListener(`snapo:${eventName}`, listener);
  return () => window.removeEventListener(`snapo:${eventName}`, listener);
}

class HttpNetworkClient implements NetworkClient {
  readonly usesNativeServerPicker = false;

  private eventSource: EventSource | null = null;
  private statusCallbacks = new Set<(status: StreamStatus) => void>();
  private eventCallbacks = new Set<(event: StreamEvent) => void>();

  async appVersion(): Promise<string> {
    return "web";
  }

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

  async saveFile(input: SaveFileInput): Promise<SaveFileResult> {
    if (input.encoding === "base64") {
      const anchor = document.createElement("a");
      anchor.href = `data:${input.mimeType ?? "application/octet-stream"};base64,${input.data}`;
      anchor.download = input.defaultPath;
      anchor.style.display = "none";
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      return { saved: true };
    }

    const blob = new Blob([input.data], { type: input.mimeType ?? "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = input.defaultPath;
    anchor.style.display = "none";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
    return { saved: true };
  }

  async debugInspectorPreset(): Promise<DebugInspectorPreset> {
    return "live";
  }

  onDebugInspectorPreset(callback: (preset: DebugInspectorPreset) => void): () => void {
    void callback;
    return () => {};
  }

  selectedDeviceChanged(deviceId: string): void {
    void deviceId;
  }

  onPreferredDevice(callback: (deviceId: string) => void): () => void {
    void callback;
    return () => {};
  }

  nativeInspectorStateChanged(state: NativeInspectorState): void {
    void state;
  }

  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void {
    void callback;
    return () => {};
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
