import type {
  InspectorServerReference,
  InvokeTweakActionInput,
  NativeTweaksState,
  TweakList,
  TweakStreamEvent,
  TweakUpdates,
  UpdateTweaksInput,
  DebugInspectorPreset,
  LoadBodiesInput,
  NativeInspectorState,
  RequestBodies,
  SaveFileInput,
  SaveFileResult,
  StartStreamInput,
  StreamEvent,
  StreamStarted,
  StreamStatus,
  InspectorHostState
} from "./bridge-types";
import type { InspectorHostClient } from "../host/client";
import { invokeNative, listenWebKitEvent, requireNativeBridge } from "../host/bridge";

export interface NativeColorPanelChange {
  color: string;
  sessionId: string;
}

export interface NetworkClient extends InspectorHostClient {
  appVersion(): Promise<string>;
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
  nativeTweaksStateChanged(state: NativeTweaksState): void;
  onNativeTweaksReset(callback: () => void): () => void;
  nativeInspectorStateChanged(state: NativeInspectorState): void;
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
  requireNativeBridge();
  return new WebKitNetworkClient();
}

class WebKitNetworkClient implements NetworkClient {
  appVersion(): Promise<string> {
    return this.invoke<string>("appVersion");
  }

  inspectorHostState(): Promise<InspectorHostState> {
    return this.invoke("inspectorHostState");
  }

  onInspectorHostState(callback: (state: InspectorHostState) => void): () => void {
    return listenWebKitEvent("inspector:state", callback);
  }

  openSelectedApp(appId: string): Promise<void> {
    return this.invoke("openSelectedApp", { appId });
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

  nativeInspectorStateChanged(state: NativeInspectorState): void {
    void this.invoke<void>("inspectorStateChanged", state);
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

  nativeTweaksStateChanged(state: NativeTweaksState): void {
    void this.invoke<void>("tweaksStateChanged", state);
  }

  onNativeTweaksReset(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("tweaks:reset", () => callback());
  }

  private async invoke<T>(command: string, payload?: unknown): Promise<T> {
    return invokeNative<T>(command, payload);
  }
}
