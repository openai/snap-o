import type {
  DebugInspectorPreset,
  InspectableApp,
  InspectorServerReference,
  InvokeTweakActionInput,
  LoadBodiesInput,
  NativeInspectorState,
  NativeTweaksState,
  RequestBodies,
  SaveFileInput,
  SaveFileResult,
  SelectedAppInspector,
  SnapOServer,
  StartStreamInput,
  StreamEvent,
  StreamStarted,
  StreamStatus,
  TweakList,
  TweakStreamEvent,
  TweakUpdates,
  UpdateTweaksInput
} from "./bridge-types";
import { inspectorProcessId } from "./inspector-process";

export interface NativeColorPanelChange {
  color: string;
  sessionId: string;
}

export interface NetworkClient {
  readonly usesNativeServerPicker: boolean;
  appVersion(): Promise<string>;
  listInspectorApps(): Promise<InspectableApp[]>;
  listServers(): Promise<SnapOServer[]>;
  listTweaks(server: InspectorServerReference): Promise<TweakList>;
  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates>;
  invokeTweakAction(input: InvokeTweakActionInput): Promise<void>;
  startTweakStream(server: InspectorServerReference): Promise<StreamStarted>;
  stopTweakStream(streamId: string): Promise<void>;
  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void;
  openNativeColorPanel?(color: string, sessionId: string, present?: boolean): Promise<void>;
  closeNativeColorPanel?(sessionId: string): Promise<void>;
  onNativeColorPanelChange?(callback: (event: NativeColorPanelChange) => void): () => void;
  loadBodies(input: LoadBodiesInput): Promise<RequestBodies>;
  startStream(input: StartStreamInput): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onEvent(callback: (event: StreamEvent) => void): () => void;
  onStatus(callback: (status: StreamStatus) => void): () => void;
  copyText(text: string): Promise<void>;
  openExternal(url: string): Promise<void>;
  saveFile(input: SaveFileInput): Promise<SaveFileResult>;
  debugInspectorPreset(): Promise<DebugInspectorPreset>;
  onDebugInspectorPreset(callback: (preset: DebugInspectorPreset) => void): () => void;
  selectedDeviceChanged(deviceId: string): void;
  onPreferredDevice(callback: (deviceId: string) => void): () => void;
  nativeInspectorStateChanged(state: NativeInspectorState): void;
  nativeTweaksStateChanged(state: NativeTweaksState): void;
  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void;
  onNativeSelectedInspector(callback: (selection: SelectedAppInspector) => void): () => void;
  onNativeTweaksReset(callback: () => void): () => void;
  onNativeSearchText(callback: (searchText: string) => void): () => void;
  onNativeSortOrder(callback: (sortNewestFirst: boolean) => void): () => void;
  onNativeClearCompleted(callback: () => void): () => void;
  onNativeCopySelectedUrl(callback: () => void): () => void;
  onNativeCopySelectedCurl(callback: () => void): () => void;
  onNativeExportVisibleHar(callback: () => void): () => void;
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

  listInspectorApps(): Promise<InspectableApp[]> {
    return this.invoke<InspectableApp[]>("listInspectorApps");
  }

  listServers(): Promise<SnapOServer[]> {
    return this.invoke<SnapOServer[]>("listServers");
  }

  listTweaks(server: InspectorServerReference): Promise<TweakList> {
    return this.invoke<TweakList>("listTweaks", server);
  }

  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates> {
    return this.invoke<TweakUpdates>("updateTweaks", input);
  }

  invokeTweakAction(input: InvokeTweakActionInput): Promise<void> {
    return this.invoke<void>("invokeTweakAction", input);
  }

  startTweakStream(server: InspectorServerReference): Promise<StreamStarted> {
    return this.invoke<StreamStarted>("startTweakStream", server);
  }

  stopTweakStream(streamId: string): Promise<void> {
    return this.invoke<void>("stopTweakStream", { streamId });
  }

  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void {
    return listenWebKitEvent<TweakStreamEvent>("tweaks:changed", callback);
  }

  openNativeColorPanel(color: string, sessionId: string, present = true): Promise<void> {
    return this.invoke<void>("openNativeColorPanel", { color, sessionId, present });
  }

  closeNativeColorPanel(sessionId: string): Promise<void> {
    return this.invoke<void>("closeNativeColorPanel", { sessionId });
  }

  onNativeColorPanelChange(callback: (event: NativeColorPanelChange) => void): () => void {
    return listenWebKitEvent<NativeColorPanelChange>("tweaks:color-panel-changed", callback);
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

  copyText(text: string): Promise<void> {
    return this.invoke<void>("copyText", { text });
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

  nativeTweaksStateChanged(state: NativeTweaksState): void {
    void this.invoke<void>("tweaksStateChanged", state);
  }

  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void {
    return listenWebKitEvent<StartStreamInput>("network:selected-server", callback);
  }

  onNativeSelectedInspector(callback: (selection: SelectedAppInspector) => void): () => void {
    return listenWebKitEvent<SelectedAppInspector>("inspector:selected", callback);
  }

  onNativeTweaksReset(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("tweaks:reset", () => callback());
  }

  onNativeSearchText(callback: (searchText: string) => void): () => void {
    return listenWebKitEvent<string>("network:search-text", callback);
  }

  onNativeSortOrder(callback: (sortNewestFirst: boolean) => void): () => void {
    return listenWebKitEvent<boolean>("network:sort-newest-first", callback);
  }

  onNativeClearCompleted(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("network:clear-completed", callback);
  }

  onNativeCopySelectedUrl(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("network:copy-selected-url", callback);
  }

  onNativeCopySelectedCurl(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("network:copy-selected-curl", callback);
  }

  onNativeExportVisibleHar(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("network:export-visible-har", callback);
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
  private tweakCallbacks = new Set<(event: TweakStreamEvent) => void>();
  private tweakEventSources = new Map<string, EventSource>();

  async appVersion(): Promise<string> {
    return "web";
  }

  async listInspectorApps(): Promise<InspectableApp[]> {
    try {
      return await fetchJson<InspectableApp[]>("/api/inspector/apps");
    } catch {
      const servers = await this.listServers();
      return servers.map((server) => ({
        id: inspectorProcessId("network", server),
        name: server.appName || server.displayName,
        packageName: server.packageName ?? server.displayName,
        deviceId: server.deviceId,
        deviceDisplayTitle: server.deviceDisplayTitle,
        appIconBase64: server.appIconBase64,
        inspectors: [
          {
            kind: "network" as const,
            server: { deviceId: server.deviceId, socketName: server.socketName },
            protocolVersion: server.protocolVersion
          }
        ]
      }));
    }
  }

  async listServers(): Promise<SnapOServer[]> {
    return fetchJson("/api/network/servers");
  }

  async listTweaks(server: InspectorServerReference): Promise<TweakList> {
    return fetchJson("/api/inspector/tweaks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(server)
    });
  }

  async updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates> {
    return fetchJson("/api/inspector/tweaks", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input)
    });
  }

  async invokeTweakAction(input: InvokeTweakActionInput): Promise<void> {
    const response = await fetch("/api/inspector/tweaks/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input)
    });
    if (response.ok) return;

    let message = `Request failed with ${response.status}`;
    try {
      const body: unknown = await response.json();
      if (
        body !== null &&
        typeof body === "object" &&
        "error" in body &&
        typeof body.error === "string" &&
        body.error.length > 0
      ) {
        message = body.error;
      }
    } catch {
      // Preserve the HTTP status when the server did not return a JSON error.
    }
    throw new Error(message);
  }

  async startTweakStream(server: InspectorServerReference): Promise<StreamStarted> {
    const streamId = crypto.randomUUID();
    const query = new URLSearchParams({
      deviceId: server.deviceId,
      socketName: server.socketName
    });
    const source = new EventSource(`/api/inspector/tweaks/events?${query.toString()}`);

    source.addEventListener("tweaks", (event) => {
      const payload = JSON.parse(event.data) as TweakList;
      const update: TweakStreamEvent = { streamId, server, tweaks: payload.tweaks };
      for (const callback of this.tweakCallbacks) callback(update);
    });

    this.tweakEventSources.set(streamId, source);
    return { streamId };
  }

  async stopTweakStream(streamId: string): Promise<void> {
    this.tweakEventSources.get(streamId)?.close();
    this.tweakEventSources.delete(streamId);
  }

  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void {
    this.tweakCallbacks.add(callback);
    return () => this.tweakCallbacks.delete(callback);
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

  copyText(text: string): Promise<void> {
    return navigator.clipboard.writeText(text);
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

  nativeTweaksStateChanged(state: NativeTweaksState): void {
    void state;
  }

  onNativeSelectedServer(callback: (server: StartStreamInput) => void): () => void {
    void callback;
    return () => {};
  }

  onNativeSelectedInspector(callback: (selection: SelectedAppInspector) => void): () => void {
    void callback;
    return () => {};
  }

  onNativeTweaksReset(callback: () => void): () => void {
    void callback;
    return () => {};
  }

  onNativeSearchText(callback: (searchText: string) => void): () => void {
    void callback;
    return () => {};
  }

  onNativeSortOrder(callback: (sortNewestFirst: boolean) => void): () => void {
    void callback;
    return () => {};
  }

  onNativeClearCompleted(callback: () => void): () => void {
    void callback;
    return () => {};
  }

  onNativeCopySelectedUrl(callback: () => void): () => void {
    void callback;
    return () => {};
  }

  onNativeCopySelectedCurl(callback: () => void): () => void {
    void callback;
    return () => {};
  }

  onNativeExportVisibleHar(callback: () => void): () => void {
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
