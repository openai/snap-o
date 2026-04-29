import { app, BrowserWindow, dialog, ipcMain, Menu, shell, type MenuItemConstructorOptions } from "electron";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NetworkInspectorBackend } from "./backend.js";
import type { LoadBodiesInput, SaveFileInput, StartStreamInput } from "../src/network/bridge-types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const backend = new NetworkInspectorBackend();

const NewWindowOffsetPx = 100;
const SnapOCheckUpdatesUrl = "snapo://check-updates";
const DockIconPath = path.join(app.getAppPath(), "resources/icons/network.png");

function createWindow(parentWindow?: BrowserWindow): BrowserWindow {
  const parentBounds = parentWindow?.getBounds();
  const window = new BrowserWindow({
    width: 1240,
    height: 820,
    minWidth: 920,
    minHeight: 620,
    ...(parentBounds == null
      ? {}
      : {
          x: parentBounds.x + NewWindowOffsetPx,
          y: parentBounds.y + NewWindowOffsetPx
        }),
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

  return window;
}

app.whenReady().then(() => {
  installApplicationIcon();
  installIpcHandlers();
  installApplicationMenu();
  createWindow();
});

app.on("window-all-closed", () => {
  app.quit();
});

app.on("before-quit", () => {
  backend.shutdown();
});

function installIpcHandlers(): void {
  ipcMain.handle("network:listServers", () => backend.listServers());
  ipcMain.handle("network:loadBodies", (_event, input: LoadBodiesInput) => backend.loadBodies(input));
  ipcMain.handle("network:startStream", (event, input: StartStreamInput) => backend.startStream(input, event.sender));
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

function installApplicationIcon(): void {
  if (process.platform === "darwin" && app.dock != null) {
    app.dock.setIcon(DockIconPath);
  }
}

function installApplicationMenu(): void {
  const template: MenuItemConstructorOptions[] = [];
  if (process.platform === "darwin") template.push(applicationMenu());
  template.push(fileMenu(), editMenu(), toolsMenu(), windowMenu());

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function applicationMenu(): MenuItemConstructorOptions {
  return {
    label: app.name,
    submenu: [
      { role: "about" },
      { type: "separator" },
      { role: "services" },
      { type: "separator" },
      { role: "hide" },
      { role: "hideOthers" },
      { role: "unhide" },
      { type: "separator" },
      { role: "quit" }
    ]
  };
}

function fileMenu(): MenuItemConstructorOptions {
  return {
    label: "File",
    submenu: [
      {
        label: "New Window",
        accelerator: "CmdOrCtrl+N",
        click: () => {
          createWindow(BrowserWindow.getFocusedWindow() ?? undefined);
        }
      },
      { type: "separator" },
      {
        label: "Close",
        accelerator: "CmdOrCtrl+W",
        click: () => {
          BrowserWindow.getFocusedWindow()?.close();
        }
      }
    ]
  };
}

function editMenu(): MenuItemConstructorOptions {
  const submenu: MenuItemConstructorOptions[] = [
    { role: "undo" },
    { role: "redo" },
    { type: "separator" },
    { role: "cut" },
    { role: "copy" },
    { role: "paste" }
  ];

  if (process.platform === "darwin") {
    submenu.push(
      { role: "pasteAndMatchStyle" },
      { role: "delete" },
      { role: "selectAll" },
      { type: "separator" },
      {
        label: "Speech",
        submenu: [{ role: "startSpeaking" }, { role: "stopSpeaking" }]
      }
    );
  } else {
    submenu.push({ role: "delete" }, { type: "separator" }, { role: "selectAll" });
  }

  return {
    label: "Edit",
    submenu
  };
}

function toolsMenu(): MenuItemConstructorOptions {
  return {
    label: "Tools",
    submenu: [
      {
        label: "Check for Updates...",
        click: () => {
          void shell.openExternal(SnapOCheckUpdatesUrl);
        }
      }
    ]
  };
}

function windowMenu(): MenuItemConstructorOptions {
  const submenu: MenuItemConstructorOptions[] = [{ role: "minimize" }, { role: "zoom" }];
  if (process.platform === "darwin") {
    submenu.push({ type: "separator" }, { role: "front" });
  } else {
    submenu.push({ role: "close" });
  }
  return {
    label: "Window",
    submenu
  };
}

function filtersForMimeType(mimeType?: string | null): Electron.FileFilter[] {
  if (mimeType === "application/json") return [{ name: "JSON", extensions: ["json"] }];
  if (mimeType === "application/har+json") return [{ name: "HAR", extensions: ["har"] }];
  return [{ name: "All Files", extensions: ["*"] }];
}
