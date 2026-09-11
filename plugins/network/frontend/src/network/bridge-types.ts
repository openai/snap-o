export interface CdpMessage {
  id?: number;
  snapoSequence?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: Record<string, unknown>;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export type ResponseBodyLoadError = "unavailable" | "failed";

export interface RequestBodies {
  requestId: string;
  requestBody?: string | null;
  responseBody?: string | null;
  responseBodyBase64Encoded?: boolean | null;
  responseBodyLoadCompleted?: boolean;
  responseBodyLoadError?: ResponseBodyLoadError | null;
}

export interface LoadBodiesInput {
  processId: string;
  requestId: string;
  includeRequestBody?: boolean;
  includeResponseBody?: boolean;
}

export interface StreamStarted {
  streamId: string;
}

export interface StreamEvent {
  streamId: string;
  processId: string;
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
  directoryKind?: "har";
}

export interface SaveFileResult {
  saved: boolean;
  path?: string | null;
}
