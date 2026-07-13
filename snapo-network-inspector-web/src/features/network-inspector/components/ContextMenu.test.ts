import { describe, expect, it } from "vitest";
import { contextMenuPosition } from "./ContextMenu";

describe("contextMenuPosition", () => {
  const viewport = { viewportWidth: 600, viewportHeight: 400 };
  const menu = { width: 190, height: 120 };

  it("keeps a menu at its requested position when it fits", () => {
    expect(contextMenuPosition({ x: 180, y: 140, ...menu, ...viewport })).toEqual({ left: 180, top: 140 });
  });

  it("moves a menu inside the right and bottom edges", () => {
    expect(contextMenuPosition({ x: 590, y: 390, ...menu, ...viewport })).toEqual({ left: 406, top: 276 });
  });

  it("keeps a menu inside the left and top edges", () => {
    expect(contextMenuPosition({ x: -20, y: -10, ...menu, ...viewport })).toEqual({ left: 4, top: 4 });
  });

  it("uses the inset when the menu is larger than the viewport", () => {
    expect(contextMenuPosition({ x: 300, y: 200, width: 800, height: 500, ...viewport })).toEqual({ left: 4, top: 4 });
  });
});
