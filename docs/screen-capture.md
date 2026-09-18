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

When Android is still booting, Snap-O waits for it to be ready and retries display discovery automatically.

Option-drag the preview to share the current frame as a screenshot, or right-click for **Copy Image** and **Save Image As…**. Each action adds that frame to Capture History. Watching the preview alone does not.

Press `Esc` to stop the preview, or `⇧⌘L` to start it again. Choose **Device → Start With** to change how new windows open.

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
