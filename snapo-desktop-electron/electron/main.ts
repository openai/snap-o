import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  shell,
  systemPreferences,
  type MenuItemConstructorOptions
} from "electron";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NetworkInspectorBackend } from "./backend.js";
import { installStandardContextMenus } from "./context-menu.js";
import { openHostUpdateUi, runStartupUpdateCheck } from "./updates.js";
import { loadWindowState, trackWindowState } from "./window-state.js";
import type { LoadBodiesInput, SaveFileInput, StartStreamInput } from "../src/network/bridge-types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const backend = new NetworkInspectorBackend();

const NewWindowOffsetPx = 100;
const DockIconPath = path.join(app.getAppPath(), "resources/icons/network.png");
const IsDevelopment = (process.env.SNAPO_ELECTRON_DEV_SERVER_URL?.length ?? 0) > 0;

function createWindow(parentWindow?: BrowserWindow): BrowserWindow {
  const windowState = loadWindowState();
  const parentBounds = parentWindow?.getBounds();
  const window = new BrowserWindow({
    width: windowState.width,
    height: windowState.height,
    minWidth: 920,
    minHeight: 620,
    ...(parentBounds == null && windowState.x != null && windowState.y != null
      ? {
          x: windowState.x,
          y: windowState.y
        }
      : parentBounds == null
        ? {}
        : {
            x: parentBounds.x + NewWindowOffsetPx,
            y: parentBounds.y + NewWindowOffsetPx
          }),
    title: "Snap-O Network Inspector",
    ...(process.platform === "darwin"
      ? {
          titleBarStyle: "hiddenInset" as const,
          trafficLightPosition: { x: 16, y: 11 }
        }
      : {}),
    backgroundColor: windowBackgroundColor(),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  if (windowState.isMaximized) window.maximize();
  trackWindowState(window);
  installStandardContextMenus(window);

  const devServerUrl = process.env.SNAPO_ELECTRON_DEV_SERVER_URL;
  if (devServerUrl != null && devServerUrl.length > 0) {
    void window.loadURL(devServerUrl);
    window.webContents.once("did-finish-load", () => {
      window.webContents.openDevTools({ mode: "detach" });
    });
  } else {
    void window.loadFile(path.join(__dirname, "../../dist-renderer/index.html"));
  }

  return window;
}

function windowBackgroundColor(): string {
  if (process.platform === "darwin") {
    return systemPreferences.getColor("window-background");
  }
  return "#f6f7f9";
}

app.whenReady().then(() => {
  installApplicationIcon();
  installIpcHandlers();
  installApplicationMenu();
  createWindow();
  void runStartupUpdateCheck();
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
  template.push(fileMenu(), editMenu());
  if (IsDevelopment) template.push(viewMenu());
  template.push(toolsMenu(), windowMenu());

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function viewMenu(): MenuItemConstructorOptions {
  return {
    label: "View",
    submenu: [
      { role: "reload" },
      { role: "forceReload" },
      { role: "toggleDevTools" },
      { type: "separator" },
      { role: "resetZoom" },
      { role: "zoomIn" },
      { role: "zoomOut" }
    ]
  };
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
  const closeItem: MenuItemConstructorOptions =
    process.platform === "darwin"
      ? { role: "close" }
      : {
          label: "Close",
          accelerator: "CmdOrCtrl+W",
          click: () => {
            BrowserWindow.getFocusedWindow()?.close();
          }
        };

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
      closeItem
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
          void openHostUpdateUi();
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
