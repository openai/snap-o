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

Option-drag the preview to share the current frame as a screenshot, or right-click for **Copy Image** and **Save Image As…**. Each action adds that frame to Capture History. Watching the preview alone does not.

Press `Esc` to stop the preview, or `⇧⌘L` to start it again. Choose **Device → Start With** to change how new windows open.

## Take a screenshot

Press `⌘R` to capture a screenshot from all connected Android devices. Use `⌘[` and `⌘]` to browse their captures. Press `⇧⌘L` to return to Live Preview.

## Record the screen

Press `⇧⌘R` to record the screens of all connected Android devices, and `Esc` to stop. The finished recordings open for playback. Step through a recording frame by frame to inspect an animation or transition.

## Drag & drop, and sharing {#drag-and-drop}

Drag a screenshot or recording from the Capture pane or Capture History into any app that accepts images or video. Dragging shares a copy and leaves the original in history. Use `⌘C` to copy a screenshot to the clipboard.

Choose **Save As…** (`⌘S`) to keep a permanent copy of the selected capture. Exported copies remain when history entries are deleted or expire.

## Capture History {#capture-history}

Capture History automatically keeps your recent screenshots and recordings on your Mac. They remain after you close their windows or restart Snap-O, so you can revisit them without the original device connected.

Open **Window → Capture History** (`⇧⌘H`) to browse captures by day, newest first.

Each capture action groups its devices into one entry. Open a group, then select a device thumbnail to view it. Use the Left and Right Arrow keys, or `⌘[` and `⌘]`, to switch devices. Press `Esc` to go back.

Drag device thumbnails within a group or its thumbnail strip to reorder them. The order is saved.

<details markdown="1" id="manage-history-storage">
<summary>Manage history storage</summary>

History keeps captures for seven days by default, with a 5 GB storage limit. Open **History Storage** in the history window's toolbar to see disk usage and change these limits.

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
