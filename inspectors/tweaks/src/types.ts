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

export interface StreamStarted {
  streamId: string;
}
