import type {
  InspectorHostState,
  InspectorServerReference,
  InvokeTweakActionInput,
  NativeTweaksState,
  StreamStarted,
  TweakList,
  TweakStreamEvent,
  TweakUpdates,
  UpdateTweaksInput
} from "../../network/bridge-types";
import type { InspectorHostClient } from "../../host/client";
import { invokeNative, listenWebKitEvent, requireNativeBridge } from "../../host/bridge";

export interface NativeColorPanelChange {
  color: string;
  sessionId: string;
}

export interface TweaksClient extends InspectorHostClient {
  listTweaks(server: InspectorServerReference): Promise<TweakList>;
  updateTweaks(input: UpdateTweaksInput): Promise<TweakUpdates>;
  invokeTweakAction(input: InvokeTweakActionInput): Promise<void>;
  startTweakStream(server: InspectorServerReference): Promise<StreamStarted>;
  stopTweakStream(streamId: string): Promise<void>;
  onTweaksChanged(callback: (event: TweakStreamEvent) => void): () => void;
  openNativeColorPanel?(color: string, sessionId: string, present?: boolean): Promise<void>;
  closeNativeColorPanel?(sessionId: string): Promise<void>;
  onNativeColorPanelChange?(callback: (event: NativeColorPanelChange) => void): () => void;
  nativeTweaksStateChanged(state: NativeTweaksState): void;
  onNativeTweaksReset(callback: () => void): () => void;
  openExternal(url: string): Promise<void>;
}

export function createTweaksClient(): TweaksClient {
  requireNativeBridge();
  return new WebKitTweaksClient();
}

class WebKitTweaksClient implements TweaksClient {
  private invoke = invokeNative;

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

  nativeTweaksStateChanged(state: NativeTweaksState): void {
    void this.invoke("tweaksStateChanged", state);
  }

  onNativeTweaksReset(callback: () => void): () => void {
    return listenWebKitEvent<boolean>("tweaks:reset", () => callback());
  }

  openExternal(url: string): Promise<void> {
    return this.invoke("openExternal", { url });
  }
}
