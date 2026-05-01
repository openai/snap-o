import { contextBridge, ipcRenderer } from "electron";
import type {
  DebugInspectorPreset,
  LoadBodiesInput,
  SaveFileInput,
  SnapONetworkBridge,
  StartStreamInput,
  StreamEvent,
  StreamStatus
} from "../src/network/bridge-types.js";

const api: SnapONetworkBridge = {
  platform: process.platform,
  appVersion: () => ipcRenderer.invoke("app:version"),
  listServers: () => ipcRenderer.invoke("network:listServers"),
  loadBodies: (input: LoadBodiesInput) => ipcRenderer.invoke("network:loadBodies", input),
  startStream: (input: StartStreamInput) => ipcRenderer.invoke("network:startStream", input),
  stopStream: (streamId: string) => ipcRenderer.invoke("network:stopStream", streamId),
  onEvent: (callback: (event: StreamEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: StreamEvent) => callback(payload);
    ipcRenderer.on("network:event", listener);
    return () => ipcRenderer.removeListener("network:event", listener);
  },
  onStatus: (callback: (status: StreamStatus) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: StreamStatus) => callback(payload);
    ipcRenderer.on("network:status", listener);
    return () => ipcRenderer.removeListener("network:status", listener);
  },
  openExternal: (url: string) => ipcRenderer.invoke("network:openExternal", url),
  saveFile: (input: SaveFileInput) => ipcRenderer.invoke("network:saveFile", input),
  debugInspectorPreset: () => ipcRenderer.invoke("debug:inspectorPreset"),
  onDebugInspectorPreset: (callback: (preset: DebugInspectorPreset) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, preset: DebugInspectorPreset) => callback(preset);
    ipcRenderer.on("debug:inspectorPreset", listener);
    return () => ipcRenderer.removeListener("debug:inspectorPreset", listener);
  }
};

contextBridge.exposeInMainWorld("snapONetwork", api);
