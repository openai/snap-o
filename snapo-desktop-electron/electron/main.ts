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
import fsSync from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NetworkInspectorBackend } from "./backend.js";
import { installStandardContextMenus } from "./context-menu.js";
import { currentVersionInfo, UpdateController, type UpdateCheckOutcome } from "./updates.js";
import { loadWindowState, trackWindowState } from "./window-state.js";
import type {
  DebugInspectorPreset,
  LoadBodiesInput,
  SaveFileInput,
  StartStreamInput
} from "../src/network/bridge-types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const backend = new NetworkInspectorBackend();
const updateController = new UpdateController(() => {
  if (app.isReady()) installApplicationMenu();
});

const NewWindowOffsetPx = 100;
const DockIconPath = path.join(app.getAppPath(), "resources/icons/network.png");
const IsDevelopment = (process.env.SNAPO_ELECTRON_DEV_SERVER_URL?.length ?? 0) > 0;
let debugInspectorPreset: DebugInspectorPreset = "live";
let logFilePath: string | null = null;

process.on("uncaughtExceptionMonitor", (error) => {
  logEvent("uncaughtException", serializeUnknown(error));
});

process.on("unhandledRejection", (reason) => {
  logEvent("unhandledRejection", serializeUnknown(reason));
});

function createWindow(parentWindow?: BrowserWindow): BrowserWindow {
  const createdAtMs = Date.now();
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
    show: false,
    ...(process.platform === "darwin"
      ? {
          titleBarStyle: "hidden" as const
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
  logEvent("windowCreated");

  window.once("ready-to-show", () => {
    logEvent("windowReadyToShow", { elapsedMs: Date.now() - createdAtMs });
    window.show();
  });
  window.webContents.once("did-finish-load", () => {
    logEvent("rendererDidFinishLoad", { elapsedMs: Date.now() - createdAtMs });
  });

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
  initializeLogging();
  logEvent("appReady", {
    appPath: app.getAppPath(),
    execPath: process.execPath,
    isPackaged: app.isPackaged
  });
  installApplicationIcon();
  installIpcHandlers();
  installApplicationMenu();
  createWindow();
  void updateController.runStartupCheck();
});

app.on("window-all-closed", () => {
  logEvent("windowAllClosed");
  app.quit();
});

app.on("before-quit", () => {
  logEvent("beforeQuit");
  backend.shutdown();
});

app.on("render-process-gone", (_event, webContents, details) => {
  logEvent("renderProcessGone", {
    webContentsId: webContents.id,
    ...details
  });
});

app.on("child-process-gone", (_event, details) => {
  logEvent("childProcessGone", details);
});

function installIpcHandlers(): void {
  ipcMain.handle("app:version", () => currentVersionInfo().version);
  ipcMain.handle("network:listServers", () => backend.listServers());
  ipcMain.handle("network:loadBodies", (_event, input: LoadBodiesInput) => backend.loadBodies(input));
  ipcMain.handle("network:startStream", (event, input: StartStreamInput) => backend.startStream(input, event.sender));
  ipcMain.handle("network:stopStream", (_event, streamId: string) => backend.stopStream(streamId));
  ipcMain.handle("network:openExternal", (_event, url: string) => shell.openExternal(url));
  ipcMain.handle("debug:inspectorPreset", () => debugInspectorPreset);
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

function initializeLogging(): void {
  app.setAppLogsPath();
  logFilePath = path.join(app.getPath("logs"), "main.log");
}

function logEvent(event: string, details?: unknown): void {
  const line = `${new Date().toISOString()} ${event}${details == null ? "" : ` ${JSON.stringify(details)}`}\n`;
  process.stderr.write(line);
  if (logFilePath == null) return;
  try {
    fsSync.mkdirSync(path.dirname(logFilePath), { recursive: true });
    fsSync.appendFileSync(logFilePath, line, "utf8");
  } catch {
    // Logging should never interfere with app startup or shutdown.
  }
}

function serializeUnknown(value: unknown): unknown {
  if (value instanceof Error) {
    return {
      name: value.name,
      message: value.message,
      stack: value.stack
    };
  }
  return value;
}

function installApplicationMenu(): void {
  const template: MenuItemConstructorOptions[] = [];
  if (process.platform === "darwin") template.push(applicationMenu());
  template.push(fileMenu(), editMenu());
  if (IsDevelopment) template.push(viewMenu());
  if (IsDevelopment) template.push(debugMenu());
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

function debugMenu(): MenuItemConstructorOptions {
  return {
    label: "Debug",
    submenu: [
      debugInspectorPresetMenuItem("Live server state", "live"),
      { type: "separator" },
      debugInspectorPresetMenuItem("Force older app protocol", "protocolOlder"),
      debugInspectorPresetMenuItem("Force newer app protocol", "protocolNewer"),
      debugInspectorPresetMenuItem("Show replacement process", "replacementProcess")
    ]
  };
}

function debugInspectorPresetMenuItem(label: string, preset: DebugInspectorPreset): MenuItemConstructorOptions {
  return {
    label,
    type: "radio",
    checked: debugInspectorPreset === preset,
    click: () => setDebugInspectorPreset(preset)
  };
}

function setDebugInspectorPreset(preset: DebugInspectorPreset): void {
  debugInspectorPreset = preset;
  for (const window of BrowserWindow.getAllWindows()) {
    window.webContents.send("debug:inspectorPreset", preset);
  }
  installApplicationMenu();
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
        label: updateController.isChecking ? "Checking for Updates..." : "Check for Updates...",
        enabled: !updateController.isChecking,
        click: () => {
          void runManualUpdateCheck();
        }
      }
    ]
  };
}

async function runManualUpdateCheck(): Promise<void> {
  const outcome = await updateController.checkForUpdates("manual");
  if (outcome === "updateAvailable" || outcome === "checking") return;
  await showManualUpdateResult(outcome);
}

function showManualUpdateResult(outcome: Exclude<UpdateCheckOutcome, "checking" | "updateAvailable">): Promise<number> {
  const window = BrowserWindow.getFocusedWindow();
  const versionInfo = currentVersionInfo();
  const options =
    outcome === "upToDate"
      ? {
          type: "info" as const,
          title: "No Updates Available",
          message: `Snap-O Network Inspector is up to date. (${versionInfo.version})`
        }
      : {
          type: "warning" as const,
          title: "Unable to Check for Updates",
          message: "Snap-O Network Inspector could not check for updates right now."
        };
  const messageBoxOptions = {
    ...options,
    buttons: ["OK"]
  };
  const result =
    window == null ? dialog.showMessageBox(messageBoxOptions) : dialog.showMessageBox(window, messageBoxOptions);
  return result.then((value) => value.response);
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
