import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NetworkInspectorBackend } from "./backend.js";
import type { LoadBodiesInput, SaveFileInput, StartStreamInput } from "../src/network/bridge-types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const backend = new NetworkInspectorBackend();

function createWindow(): void {
  const window = new BrowserWindow({
    width: 1240,
    height: 820,
    minWidth: 920,
    minHeight: 620,
    title: "Snap-O Network Inspector",
    backgroundColor: "#f6f7f9",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  const devServerUrl = process.env.SNAPO_ELECTRON_DEV_SERVER_URL;
  if (devServerUrl != null && devServerUrl.length > 0) {
    void window.loadURL(devServerUrl);
  } else {
    void window.loadFile(path.join(__dirname, "../../dist-renderer/index.html"));
  }
}

app.whenReady().then(() => {
  installIpcHandlers();
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  backend.shutdown();
});

function installIpcHandlers(): void {
  ipcMain.handle("network:listServers", () => backend.listServers());
  ipcMain.handle("network:loadBodies", (_event, input: LoadBodiesInput) => backend.loadBodies(input));
  ipcMain.handle("network:startStream", (event, input: StartStreamInput) =>
    backend.startStream(input, event.sender)
  );
  ipcMain.handle("network:stopStream", (_event, streamId: string) => backend.stopStream(streamId));
  ipcMain.handle("network:openExternal", (_event, url: string) => shell.openExternal(url));
  ipcMain.handle("network:saveFile", async (_event, input: SaveFileInput) => {
    const result = await dialog.showSaveDialog({
      defaultPath: input.defaultPath,
      filters: filtersForMimeType(input.mimeType)
    });
    if (result.canceled || result.filePath == null) return { saved: false };
    await fs.writeFile(result.filePath, input.data, "utf8");
    return { saved: true, path: result.filePath };
  });
}

function filtersForMimeType(mimeType?: string | null): Electron.FileFilter[] {
  if (mimeType === "application/json") return [{ name: "JSON", extensions: ["json"] }];
  if (mimeType === "application/har+json") return [{ name: "HAR", extensions: ["har"] }];
  return [{ name: "All Files", extensions: ["*"] }];
}
