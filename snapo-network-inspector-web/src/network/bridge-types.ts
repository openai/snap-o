export interface SnapOServer {
  server: string;
  deviceId: string;
  socketName: string;
  deviceDisplayTitle: string;
  displayName: string;
  isConnected: boolean;
  hasAppInfo: boolean;
  pid?: number | null;
  protocolVersion?: number | null;
  isProtocolNewerThanSupported: boolean;
  isProtocolOlderThanSupported: boolean;
  appIconBase64?: string | null;
  packageName?: string | null;
  appName?: string | null;
}

export interface NativeInspectorState {
  servers: SnapOServer[];
  selectedServer: StartStreamInput | null;
  searchText: string;
  sortNewestFirst: boolean;
  hasClearableItems: boolean;
  selectedRecordKind: "request" | "websocket" | null;
  hasVisibleRecords: boolean;
}

export interface CdpMessage {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: Record<string, unknown>;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export interface RequestBodies {
  requestId: string;
  requestBody?: string | null;
  responseBody?: string | null;
  responseBodyBase64Encoded?: boolean | null;
}

export interface LoadBodiesInput {
  deviceId: string;
  socketName: string;
  requestId: string;
  includeRequestBody?: boolean;
  includeResponseBody?: boolean;
}

export interface StartStreamInput {
  deviceId: string;
  socketName: string;
}

export interface StreamStarted {
  streamId: string;
}

export interface StreamEvent {
  streamId: string;
  server: StartStreamInput;
  message: CdpMessage;
}

export type StreamStatusState = "started" | "stderr" | "exit" | "error";

export interface StreamStatus {
  streamId: string;
  state: StreamStatusState;
  message?: string;
  code?: number | null;
  signal?: string | null;
}

export interface SaveFileInput {
  defaultPath: string;
  data: string;
  mimeType?: string | null;
  encoding?: "utf8" | "base64";
}

export interface SaveFileResult {
  saved: boolean;
  path?: string | null;
}

export type DebugInspectorPreset = "live" | "protocolOlder" | "protocolNewer" | "replacementProcess";
