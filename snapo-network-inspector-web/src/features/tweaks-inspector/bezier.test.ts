import { describe, expect, it } from "vitest";
import { bezierValue, moveBezier, readBezier, bezierViewport, bezierGraphY, bezierCoordinateY } from "./bezier";

describe("Bezier values", () => {
  it("round trips overshoot coordinates", () => {
    const curve = [0.2, -0.5, 0.8, 1.5] as const;
    expect(readBezier(bezierValue(curve))).toEqual(curve);
  });
  it.each([
    { x1: 2, y1: 0, x2: 1, y2: 1 },
    { x1: 0, y1: -Infinity, x2: 1, y2: 1 },
    { x1: 0, y1: 0, x2: 1, y2: Infinity },
    { x1: 0, y1: NaN, x2: 1, y2: 1 },
    { x1: 0, y1: 0, x2: 1 },
    { x1: 0, y1: 0, x2: 1, y2: 1, extra: 2 },
    { x1: 0, y1: "0", x2: 1, y2: 1 },
    "cubic-bezier(0, 0, 1, 1)"
  ])("rejects malformed coordinate objects", (value) => {
    expect(readBezier(value)).toBeNull();
  });
  it("moves one handle, preserving the other and clamping only X", () => {
    expect(moveBezier([0.2, 0.3, 0.8, 0.9], 0, -1, 2)).toEqual([0, 2, 0.8, 0.9]);
    expect(moveBezier([0.2, 0.3, 0.8, 0.9], 1, 0.7, 2)).toEqual([0.2, 0.3, 0.7, 2]);
  });
  it("fits and round trips overshoot and finite Float extremes", () => {
    for (const limit of [2, 3.4028234663852886e38]) {
      const curve = [0.2, -limit, 0.8, limit] as const;
      expect(readBezier(bezierValue(curve))).toEqual(curve);
      const viewport = bezierViewport(curve);
      for (const y of [0, 1, -limit, limit]) {
        const position = bezierGraphY(y, viewport);
        expect(Number.isFinite(position)).toBe(true);
        expect(position).toBeGreaterThanOrEqual(0);
        expect(position).toBeLessThanOrEqual(1);
      }
      expect(bezierCoordinateY(bezierGraphY(-limit, viewport), viewport)).toBe(-limit);
      expect(bezierCoordinateY(bezierGraphY(limit, viewport), viewport)).toBe(limit);
    }
  });
  it("ignores non-finite handle movement", () => {
    const curve = [0, 0, 1, 1] as const;
    expect(moveBezier(curve, 0, 0.5, Infinity)).toBe(curve);
    expect(moveBezier(curve, 0, NaN, 0.5)).toBe(curve);
  });
});
