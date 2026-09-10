export interface BezierValue {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

export type TweakValue = boolean | number | string | BezierValue;

export interface TweakValueDescriptor {
  name: string;
  type: "int" | "float" | "boolean" | "color" | "string" | "enum" | "bezier";
  default: TweakValue;
  value: TweakValue;
  modified?: boolean;
  min?: number;
  max?: number;
  step?: number;
  options?: string[];
}

export interface TweakActionDescriptor {
  name: string;
  type: "action";
  conflicted?: boolean;
}

export type TweakDescriptor = TweakValueDescriptor | TweakActionDescriptor;

export interface TweakList {
  tweaks: TweakDescriptor[];
}

export interface TweakStreamEvent extends TweakList {
  streamId: string;
}

export interface TweakUpdate {
  name: string;
  value: TweakValue;
  modified?: boolean;
}

export interface TweakUpdateError {
  name: string;
  error: string;
}

export interface TweakUpdates {
  tweaks: TweakUpdate[];
  errors?: TweakUpdateError[];
}

export interface UpdateTweaksInput {
  values: Record<string, TweakValue | null>;
}

export interface InvokeTweakActionInput {
  name: string;
}

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
