import type { BezierValue } from "../../network/bridge-types";

export type BezierCoordinates = readonly [number, number, number, number];

export function readBezier(value: unknown): BezierCoordinates | null {
  if (typeof value !== "object" || value === null) return null;
  const object = value as Record<string, unknown>;
  const points = [object.x1, object.y1, object.x2, object.y2];
  if (Object.keys(object).length !== 4 || points.some((v) => typeof v !== "number" || !Number.isFinite(Math.fround(v))))
    return null;
  const coordinates = points as unknown as BezierCoordinates;
  if ([coordinates[0], coordinates[2]].some((v) => v < 0 || v > 1)) return null;
  return coordinates;
}

export function bezierValue([x1, y1, x2, y2]: BezierCoordinates): BezierValue {
  return { x1, y1, x2, y2 };
}

export function moveBezier(value: BezierCoordinates, index: number, x: number, y: number): BezierCoordinates {
  if (!Number.isFinite(Math.fround(x)) || !Number.isFinite(Math.fround(y))) return value;
  const next = [...value];
  next[index * 2] = Math.max(0, Math.min(1, Number(x.toFixed(6))));
  next[index * 2 + 1] = Number(y.toFixed(6));
  return next as unknown as BezierCoordinates;
}

export const bezierPresets: Record<string, BezierCoordinates> = {
  Linear: [1 / 3, 1 / 3, 2 / 3, 2 / 3],
  Ease: [0.25, 0.1, 0.25, 1],
  "Ease in": [0.42, 0, 1, 1],
  "Ease out": [0, 0, 0.58, 1],
  "Ease in out": [0.42, 0, 0.58, 1]
};

export interface BezierViewport {
  bottom: number;
  top: number;
}

export function bezierViewport(value: BezierCoordinates): BezierViewport {
  return { bottom: Math.min(-0.5, value[1], value[3]), top: Math.max(1.5, value[1], value[3]) };
}

export function bezierGraphY(y: number, viewport: BezierViewport): number {
  return (viewport.top - y) / (viewport.top - viewport.bottom);
}

export function bezierCoordinateY(position: number, viewport: BezierViewport): number {
  return viewport.top - position * (viewport.top - viewport.bottom);
}
