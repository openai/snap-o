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
  originalResponseBody?: string | null;
  originalResponseBodyBase64Encoded?: boolean | null;
  originalResponseBodyLoadCompleted?: boolean;
  originalResponseBodyLoadError?: ResponseBodyLoadError | null;
}

export interface LoadBodiesInput {
  processId: string;
  requestId: string;
  includeRequestBody?: boolean;
  includeResponseBody?: boolean;
  includeOriginalResponseBody?: boolean;
}

export interface StreamStarted {
  streamId: string;
}

export interface StreamEvent {
  streamId: string;
  processId: string;
  message: CdpMessage;
}

export interface StreamClosed {
  streamId: string;
}
