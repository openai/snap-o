---
layout: guide
title: "Screen capture · Snap-O"
description: Use Live Preview, take screenshots and recordings, and revisit captures in Snap-O.
styles:
- guide.css
- network-inspector.css
- screen-capture.css
languages:
- bash
breadcrumbs:
- label: Snap-O
  href: index.html
---

# Screen capture

Snap-O makes it easier to capture and share Android screens, with instant previews and screenshots or recordings from all connected devices at once. Drag and drop captures into your work, and revisit them later in Capture History.
{.lead}

## Live Preview

Snap-O opens in Live Preview by default. Click and drag within the preview to interact with the device. Use `⌘[` and `⌘]` to switch between connected devices.

The device picker shows a live thumbnail for the selected device and cached screenshots for the others. Devices stay in the same order when you switch between them.

You can open an emulator preview while Android is still booting. The emulator screen can appear before Android is ready for input. Snap-O retries display discovery and emulator control discovery automatically. Rotation and supported display or posture controls become available without reopening the preview.

Hold Option and drag to use two touch points for pinch or rotation gestures. Hold Option-Shift while dragging to move both points together. The touch markers show where the gesture will act.

Command-drag the preview to share the current frame as a screenshot, or right-click for **Copy Image** and **Save Image As…**. Each action adds that frame to Capture History. Watching the preview alone does not.

Press `Esc` to stop the preview, or `⇧⌘L` to start it again. Choose **Device → Start With** to change how new windows open.

## Device and emulator controls

Live Preview shows floating controls beside the Capture window. Use **Back**, **Home**, **Recents**, **Volume Down**, **Volume Up**, and **Power/Wake** to control the selected device.

Emulators also offer **Rotate Left** and **Rotate Right**. Supported emulators show **Display Mode** and **Posture** menus. Available choices depend on the emulator. These controls can remain unavailable during boot; Snap-O retries automatically.

Right-click the controls and choose **Position → Left of Window** or **Position → Below Capture Pane**. Snap-O remembers this position and keeps the controls within the screen. They hide when Snap-O becomes inactive.

## Clipboard sync

The **Sync clipboard** button in the floating controls toggles text sync between Mac and Android. This is a global setting, shared by every Capture window. It is on by default, and Snap-O remembers your choice after restarting.

Only the focused Capture window in Live Preview can sync its selected device. Visible background windows do not sync. Sync stops when the window loses focus, Snap-O becomes inactive, the preview closes, or the toggle is turned off. Focusing another Live Preview window switches sync to that window's device.

When sync starts, supported text already on the Mac takes priority. Android text fills an empty Mac clipboard. Images, files, empty text, and text larger than 1 MiB are not synced. Existing Mac clipboard items are preserved when sync starts, even if they cannot be synced. A newer Mac copy takes priority over an incoming Android update.

If the clipboard connection is unavailable, Snap-O retries. Hover over the clipboard button to check its status.

## Send files and install APKs

Drop regular files from Finder onto Live Preview to copy them into the selected device's **Downloads** folder. Folders and symbolic links are not supported. If a filename already exists, choose **Keep Both**, **Replace**, or **Skip**.

Dropping APK files opens a prompt. Choose **Install** to install them, **Copy to Downloads** to copy them without installing, or **Cancel**. When a drop contains APKs and other files, **Install** installs the APKs and copies the remaining files to Downloads.

Progress and transfer errors appear at the bottom of the preview. Device policy can block transfers. Closing the preview cancels the remaining work.

## Device Manager {#device-manager}

[Snap-O 11.0.0](https://github.com/openai/snap-o/releases/tag/11.0.0) adds Device Manager for existing Android emulators and connected devices. Open **Device → Device Manager**, or use the Capture title's ellipsis menu.

Click **Start** beside a stopped emulator. The row shows startup progress until Android finishes booting. Click **Open** to select a running emulator or connected phone in Live Preview and focus Capture. Start and Cold Boot do not select a device or focus Capture. Double-clicking a thumbnail also opens a running device or starts a stopped emulator.

Use **Stop** to shut down an emulator, or **Cold Boot** in its actions menu to start without loading a saved snapshot. **Reveal in Finder** opens its files. **Delete** asks for confirmation before moving a stopped emulator and its data to Trash. Connected phones have no emulator lifecycle controls.

Device Manager uses your installed Android SDK and existing AVDs. The default SDK location is `~/Library/Android/sdk`. It also checks `ANDROID_HOME` and `ANDROID_SDK_ROOT` when available to the app; apps opened from Finder do not inherit shell startup variables. This version does not install SDK packages, create or edit AVDs, or offer a custom SDK location picker.

Quitting Snap-O leaves running emulators available to other tools.

## Take a screenshot

Press `⌘R` to capture a screenshot from all connected Android devices. Use `⌘[` and `⌘]` to browse their captures. Press `⇧⌘L` to return to Live Preview.

## Record the screen

Press `⇧⌘R` to record the screens of all connected Android devices, and `Esc` to stop. The finished recordings open for playback. Step through a recording frame by frame to inspect an animation or transition.

## Drag & drop, and sharing {#drag-and-drop}

Drag a screenshot or recording from the Capture pane or Capture History into any app that accepts images or video. Dragging shares a copy and leaves the original in history. Use `⌘C` to copy a screenshot to the clipboard.

Choose **Save As…** (`⌘S`) to keep a permanent copy of the selected capture. Saved and dragged files use the capture name when you have assigned one. Exported copies remain when history entries are deleted or expire.

## Capture History {#capture-history}

Capture History automatically keeps your recent screenshots and recordings on your Mac. They remain after you close their windows or restart Snap-O, so you can revisit them without the original device connected.

Open **Window → Capture History** (`⇧⌘H`) to browse captures by day, newest first.

Each capture action groups its devices into one entry. Open a capture to preview it immediately. Use the toolbar thumbnails, Left and Right Arrow keys, or `⌘[` and `⌘]` to switch devices. Press `Esc` to return to history.

Captures start as **Untitled**. Click the name in the Capture pane or history preview to rename it. In the history grid, double-click the name or choose **Rename…** from the context menu. The name applies to all devices in that capture.

<details markdown="1" id="manage-history-storage">
<summary>Manage history storage</summary>

History keeps captures for 30 days by default, with a 5 GB storage limit. Open **History Storage** in the history window's toolbar to see disk usage and change these limits. If you have not chosen a retention period, it follows the current app default.

Snap-O removes the oldest captures when either limit is reached. All devices in an entry are removed together. Captures that are recording or in use are kept. The newest capture is kept for 24 hours if it exceeds the storage limit, so usage can temporarily exceed the limit.

To remove a group, open it and choose **Delete Capture**. **Clear History…** removes all entries that are no longer recording or in use. Close other viewers first if a capture cannot be deleted. Snap-O asks for confirmation before applying storage settings that remove older captures.

</details>

## Keyboard shortcuts

| Action                    | Shortcut |
|---------------------------|----------|
| New screenshot            | `⌘R`     |
| Start recording           | `⇧⌘R`    |
| Start live preview        | `⇧⌘L`    |
| Stop recording / preview  | `⎋`      |
| Open Capture History      | `⇧⌘H`    |
| Save as                   | `⌘S`     |
| Copy image to clipboard   | `⌘C`     |
| Previous device           | `⌘[`     |
| Next device               | `⌘]`     |
| Show / hide Capture       | `⌥⌘C`    |
