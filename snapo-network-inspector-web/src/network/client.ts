import type {
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

export interface NetworkClient extends InspectorHostClient {
  appVersion(): Promise<string>;
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

  private async invoke<T>(command: string, payload?: unknown): Promise<T> {
    return invokeNative<T>(command, payload);
  }
}
