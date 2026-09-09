import type {
  AppInspectorState,
  DebugInspectorPreset,
  InspectableApp,
  InspectorServerReference,
  InvokeTweakActionInput,
  LoadBodiesInput,
  NativeInspectorState,
  NativeTweaksState,
  OpenAppInput,
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

export interface NativeColorPanelChange {
  color: string;
  sessionId: string;
}

export interface NetworkClient {
  appVersion(): Promise<string>;
  listInspectorApps(): Promise<InspectableApp[]>;
  openApp?(app: OpenAppInput): Promise<void>;
  loadInspectorPreferences(): Promise<string | null>;
  saveInspectorPreferences(value: string): Promise<void>;
  appInspectorStateChanged(state: AppInspectorState): void;
  onNativeSelectedApp(callback: (appId: string) => void): () => void;
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
  listExclusionFilters(): Promise<string[]>;
  addExclusionFilter(filter: string): Promise<void>;
  removeExclusionFilter(filter: string): Promise<void>;
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
  onNativeExclusionFilters(callback: (filters: string[]) => void): () => void;
  onNativeSortOrder(callback: (sortNewestFirst: boolean) => void): () => void;
  onNativeClearCompleted(callback: () => void): () => void;
  onNativeCopySelectedUrl(callback: () => void): () => void;
  onNativeCopySelectedCurl(callback: () => void): () => void;
  onNativeExportVisibleHar(callback: () => void): () => void;
}

export type InspectorContentClient = Pick<NetworkClient, "copyText" | "saveFile">;

export function createNetworkClient(): NetworkClient {
  if (webKitMessageHandler() == null) throw new Error("Open this inspector in the Snap-O macOS app.");
  return new WebKitNetworkClient();
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
  appVersion(): Promise<string> {
    return this.invoke<string>("appVersion");
  }

  listInspectorApps(): Promise<InspectableApp[]> {
    return this.invoke<InspectableApp[]>("listInspectorApps");
  }

  openApp(app: OpenAppInput): Promise<void> {
    return this.invoke<void>("openApp", app);
  }

  loadInspectorPreferences(): Promise<string | null> {
    return this.invoke<string | null>("loadInspectorPreferences");
  }

  saveInspectorPreferences(value: string): Promise<void> {
    return this.invoke<void>("saveInspectorPreferences", { value });
  }

  appInspectorStateChanged(state: AppInspectorState): void {
    void this.invoke<void>("appInspectorStateChanged", state);
  }

  onNativeSelectedApp(callback: (appId: string) => void): () => void {
    return listenWebKitEvent<string>("inspector:app-selected", callback);
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

  listExclusionFilters(): Promise<string[]> {
    return this.invoke<string[]>("listExclusionFilters");
  }

  addExclusionFilter(filter: string): Promise<void> {
    return this.invoke<void>("addExclusionFilter", { filter });
  }

  removeExclusionFilter(filter: string): Promise<void> {
    return this.invoke<void>("removeExclusionFilter", { filter });
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

  onNativeExclusionFilters(callback: (filters: string[]) => void): () => void {
    return listenWebKitEvent<string[]>("network:exclusion-filters", callback);
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
