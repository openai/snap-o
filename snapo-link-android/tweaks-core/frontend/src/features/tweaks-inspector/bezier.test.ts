import { describe, expect, it } from "vitest";
import { bezierValue, moveBezier, readBezier } from "./bezier";

describe("Bezier values", () => {
  it("round trips normalized coordinates", () => {
    const curve = [0.2, 0.1, 0.8, 0.9] as const;
    expect(readBezier(bezierValue(curve))).toEqual(curve);
  });
  it.each([
    { x1: 2, y1: 0, x2: 1, y2: 1 },
    { x1: 0, y1: -0.1, x2: 1, y2: 1 },
    { x1: 0, y1: 0, x2: 1, y2: 1.1 },
    { x1: 0, y1: NaN, x2: 1, y2: 1 },
    { x1: 0, y1: 0, x2: 1 },
    { x1: 0, y1: 0, x2: 1, y2: 1, extra: 2 },
    { x1: 0, y1: "0", x2: 1, y2: 1 },
    "cubic-bezier(0, 0, 1, 1)"
  ])("rejects malformed coordinate objects", (value) => {
    expect(readBezier(value)).toBeNull();
  });
  it("moves one handle, preserving the other and clamping coordinates to zero through one", () => {
    expect(moveBezier([0.2, 0.3, 0.8, 0.9], 0, -1, 2)).toEqual([0, 1, 0.8, 0.9]);
    expect(moveBezier([0.2, 0.3, 0.8, 0.9], 1, 0.7, 2)).toEqual([0.2, 0.3, 0.7, 1]);
  });
});
