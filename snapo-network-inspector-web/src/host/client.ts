import type { InspectorHostState } from "../network/bridge-types";

export interface InspectorHostClient {
  inspectorHostState(): Promise<InspectorHostState>;
  onInspectorHostState(callback: (state: InspectorHostState) => void): () => void;
  openSelectedApp(appId: string): Promise<void>;
}
