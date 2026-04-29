import {
  BrowserWindow,
  Menu,
  type ContextMenuParams,
  type MenuItemConstructorOptions,
  type WebContents
} from "electron";

export function installStandardContextMenus(window: BrowserWindow): void {
  window.webContents.on("context-menu", (_event, params) => {
    const template = contextMenuTemplate(params, window.webContents);
    if (template.length === 0) return;
    Menu.buildFromTemplate(template).popup({ window });
  });
}

function contextMenuTemplate(params: ContextMenuParams, webContents: WebContents): MenuItemConstructorOptions[] {
  if (params.mediaType === "image" && params.srcURL.length > 0) {
    return imageMenuTemplate(params, webContents);
  }
  if (params.isEditable) {
    return editableTextMenuTemplate(params);
  }
  if (params.selectionText.trim().length > 0) {
    return selectedTextMenuTemplate(params);
  }
  return [];
}

function imageMenuTemplate(params: ContextMenuParams, webContents: WebContents): MenuItemConstructorOptions[] {
  return [
    {
      label: "Copy Image",
      click: () => webContents.copyImageAt(params.x, params.y)
    },
    {
      label: "Save Image As...",
      click: () => webContents.downloadURL(params.srcURL)
    }
  ];
}

function editableTextMenuTemplate(params: ContextMenuParams): MenuItemConstructorOptions[] {
  return [
    { role: "cut", enabled: params.editFlags.canCut },
    { role: "copy", enabled: params.editFlags.canCopy },
    { role: "paste", enabled: params.editFlags.canPaste },
    { type: "separator" },
    { role: "selectAll", enabled: params.editFlags.canSelectAll }
  ];
}

function selectedTextMenuTemplate(params: ContextMenuParams): MenuItemConstructorOptions[] {
  return [
    { role: "copy", enabled: params.editFlags.canCopy },
    { type: "separator" },
    { role: "selectAll", enabled: params.editFlags.canSelectAll }
  ];
}
