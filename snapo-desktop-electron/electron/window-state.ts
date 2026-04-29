import { app, BrowserWindow, screen, type Rectangle } from "electron";
import fs from "node:fs";
import path from "node:path";

export interface PersistedWindowState {
  width: number;
  height: number;
  x?: number;
  y?: number;
  isMaximized: boolean;
}

const DefaultWindowState: PersistedWindowState = {
  width: 1240,
  height: 820,
  isMaximized: false
};
const SaveDebounceMs = 250;

export function loadWindowState(): PersistedWindowState {
  try {
    const raw = fs.readFileSync(windowStatePath(), "utf8");
    const parsed = JSON.parse(raw) as Partial<PersistedWindowState>;
    const width = validDimension(parsed.width) ? parsed.width : DefaultWindowState.width;
    const height = validDimension(parsed.height) ? parsed.height : DefaultWindowState.height;
    const candidate = {
      width,
      height,
      x: validCoordinate(parsed.x) ? parsed.x : undefined,
      y: validCoordinate(parsed.y) ? parsed.y : undefined,
      isMaximized: parsed.isMaximized === true
    };
    return hasVisiblePosition(candidate) ? candidate : { ...candidate, x: undefined, y: undefined };
  } catch {
    return { ...DefaultWindowState };
  }
}

export function trackWindowState(window: BrowserWindow): void {
  let saveTimer: NodeJS.Timeout | null = null;
  const scheduleSave = () => {
    if (saveTimer != null) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      saveTimer = null;
      saveWindowState(window);
    }, SaveDebounceMs);
  };

  window.on("resize", scheduleSave);
  window.on("move", scheduleSave);
  window.on("maximize", scheduleSave);
  window.on("unmaximize", scheduleSave);
  window.on("close", () => {
    if (saveTimer != null) clearTimeout(saveTimer);
    saveWindowState(window);
  });
}

function saveWindowState(window: BrowserWindow): void {
  const normalBounds = window.getNormalBounds();
  const nextState: PersistedWindowState = {
    width: normalBounds.width,
    height: normalBounds.height,
    x: normalBounds.x,
    y: normalBounds.y,
    isMaximized: window.isMaximized()
  };
  try {
    fs.mkdirSync(path.dirname(windowStatePath()), { recursive: true });
    fs.writeFileSync(windowStatePath(), `${JSON.stringify(nextState)}\n`, "utf8");
  } catch {
    // Persistence should not block the inspector from opening or closing.
  }
}

function windowStatePath(): string {
  return path.join(app.getPath("userData"), "window-state.json");
}

function validDimension(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function validCoordinate(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function hasVisiblePosition(state: PersistedWindowState): boolean {
  if (state.x == null || state.y == null) return true;
  const bounds: Rectangle = { x: state.x, y: state.y, width: state.width, height: state.height };
  return screen.getAllDisplays().some((display) => rectanglesOverlap(bounds, display.workArea));
}

function rectanglesOverlap(left: Rectangle, right: Rectangle): boolean {
  return (
    left.x < right.x + right.width &&
    left.x + left.width > right.x &&
    left.y < right.y + right.height &&
    left.y + left.height > right.y
  );
}
