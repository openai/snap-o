---
layout: guide
title: "Screen capture · Snap-O"
description: Use Live Preview, crop screenshots, trim recordings, and save captures in Snap-O.
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

Capture a screenshot or recording of the selected Android device, then crop or trim it before sharing. Save captures you want to keep in Capture History.
{.lead}

## Live Preview

Snap-O opens in Live Preview by default. Click and drag within the preview to interact with the device. Use `⌘[` and `⌘]` to switch between connected devices.

Hover over the device count to choose a preview. The picker shows a live thumbnail for the selected device and cached screenshots for the others. It appears only when more than one device is available. Devices stay in the same order when you switch between them.

You can preview the same device in multiple Snap-O windows. Each window keeps its own selection.

You can open an emulator preview while Android is still booting. The emulator screen can appear before Android is ready for input. Snap-O retries display discovery and emulator control discovery automatically. Rotation and supported display or posture controls become available without reopening the preview.

Hold Option and drag to use two touch points for pinch or rotation gestures. Hold Option-Shift while dragging to move both points together. The touch markers show where the gesture will act.

Command-drag the preview to share the current frame as a screenshot, or right-click for **Copy Image** and **Save Image As…**. Each action adds that frame to Capture History. Watching the preview alone does not.

With keyboard focus outside the device image, press `Esc` to stop the preview, or `⇧⌘L` to start it again. Choose **Device → Start With** to change how new windows open.

## Device and emulator controls

Live Preview shows floating controls beside the Capture window. Use **Back**, **Home**, **Recents**, **Volume Down**, **Volume Up**, and **Power/Wake** to control the selected device.

Physical devices and emulators offer **Rotate Left** and **Rotate Right**. Emulator rotation changes the virtual device’s orientation through its sensors. Physical-device rotation temporarily locks the orientation; Snap-O restores the original rotation mode when live preview ends. Apps that require a fixed orientation may stay in that orientation. Supported emulators show **Display Mode** and **Posture** menus. Available choices depend on the emulator. Display and posture controls can remain unavailable during boot; Snap-O retries automatically.

Right-click the controls and choose **Position → Left of Window** or **Position → Below Capture Pane**. Snap-O remembers this position. The controls stay anchored outside the window, even when that places them offscreen. They hide when Snap-O becomes inactive.

## Keyboard input

Click the device image to type, delete text, or use arrow keys. **Keyboard input** is on by default; toggle it in the floating controls. Click outside the image to release keyboard focus.

While the device image has keyboard focus, `⌘C` copies selected Android text and `⌘V` pastes Mac text into Android. These actions also work with clipboard sync off. Use Paste for characters the Android keyboard cannot type, including emoji. To copy the preview image, use its **Copy Image** context menu.

`Esc` goes to Android while the image has keyboard focus, unless it cancels an active gesture or text composition.

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

When the local ADB server is missing, Snap-O starts it using your Android SDK. Existing ADB connections, including remote tunnels, are left in place. If startup fails, the Capture pane shows the error and a **Start ADB server** button.

Quitting Snap-O leaves running emulators available to other tools.

### Open a device from a link

Use `snapo://open` without parameters to show the current device’s Live Preview. To select a connected device, include its ADB serial:

```bash
open 'snapo://open?serial=emulator-5554'
```

You can also open an emulator by its AVD name. Add `start=true` to start it if it is stopped:

```bash
open 'snapo://open?avd=Pixel_8&start=true'
```

Use either `serial` or `avd`, and percent-encode spaces or other special characters in its value.

<details markdown="1" id="remote-adb">
<summary>ADB servers</summary>

If you have an ADB server on another computer accessible via SSH, you can connect to it with Snap-O. Open **Device → ADB Servers…** and click **Add Server**.

Set up SSH access in your Terminal first. Snap-O cannot display SSH login or host-key prompts. The SSH server must allow port forwarding. The ADB server must already be running on the remote computer’s loopback address (`127.0.0.1`, port `5037` by default).

To open a device on an already-connected SSH server, use its saved SSH destination:

```bash
open 'snapo://open?serial=emulator-5554&server=devbox&port=2222&adb_port=5038'
```

`server` matches the saved destination exactly, including an SSH config alias or `user@host`. `port` matches the saved SSH port override; omit it when no override is configured. If omitted, the destination and ADB port must identify one enabled server. `adb_port` defaults to `5037`.

Omit `server` or use `server=localhost` for the local ADB server. These connection parameters apply only to `serial` links; `port` applies only to SSH servers. For a saved but disabled SSH server, Snap-O asks you to enable it and open the requested device. Cancel leaves the server disabled. Links wait for connection and device discovery after approval. Unknown servers must still be added in ADB Servers first.

</details>

## Take a screenshot

Press `⇧⌘S` to capture a screenshot of the device shown in the window. The screenshot opens for review.

## Record the screen

Press `⇧⌘V` to start recording the device shown in the window. Press it again to stop. Live Preview stays interactive during regular recordings, so you can continue using the device. Enabling **Record Screen as Bug Report** stops Live Preview during recording. The finished recording opens for review. Press Space to pause or resume playback, use the timeline to scrub, or change the playback speed. Left and Right Arrow step through frames to inspect an animation or transition.

The window stays on the recording device until you stop. To capture another device at the same time, open another window and select that device.

## Review, crop, and trim {#review-and-crop}

New screenshots and recordings stay in review until you save or discard them. Drag an edge or corner of the crop boundary to resize it. Once cropped, drag inside the boundary to move the crop.

For a recording, click the scissors to trim it. Drag the timeline handles or edit **Start** and **End**, then click **Apply Trim**. Press `Esc` to cancel the trim edit. Saved and shared copies use the selected crop and trim.

Click the checkmark (**Save to History**) to keep the capture with its crop and trim. Enter an optional name, then click **Save**. Click the cross (**Discard**) to remove the unsaved capture and return to Live Preview.

Press `Esc` to open a discard confirmation. Press `Enter` to discard, or `Esc` again to keep editing. During a crop drag or while trimming a recording, `Esc` cancels that edit first.

Starting another capture, pressing `⇧⌘L` to return to Live Preview, closing the window, or quitting discards unsaved captures without a prompt. Save them to Capture History first if you want to keep them.

## Drag & drop, and sharing {#drag-and-drop}

Drag a screenshot or recording into any app that accepts images or video. During review, hold Command and drag inside a crop to share the cropped copy; an uncropped capture can be dragged normally. Sharing a copy does not add the capture to history. Click the checkmark if you also want to keep it there.

You can also drag saved captures from Capture History. Their originals remain in history. Use `⌘C` to copy a screenshot to the clipboard.

Choose **Save As…** (`⌘S`) to export the selected capture with its current crop and trim. This saves a file without adding it to Capture History. Saved and dragged files use the capture name when you have assigned one. Exported copies remain when you discard the review or delete the history entry.

## Capture History {#capture-history}

Capture History keeps the screenshots and recordings you save from review, along with frames shared from Live Preview. They remain on your Mac after you close their windows or restart Snap-O, so you can revisit them without the original device connected.

Open **Window → Capture History** (`⌘Y`) to browse captures by day, newest first.

Each new capture creates one entry. Existing entries can contain multiple captures. Double-click an entry to preview it. For a grouped entry, use the toolbar thumbnails, Left and Right Arrow keys, or `⌘[` and `⌘]` to switch captures. Press `Esc` to return to history.

Captures saved without a name appear as **Untitled**. Click the name in the history preview to rename it, or choose **Rename** from the history grid's context menu. The name applies to all captures in the entry.

Click an entry to select it. Command-click toggles individual entries; Shift-click selects a range. Drag from empty grid space, including padding inside an entry, to select entries with a rectangle. Hold Command or Shift while dragging to add to the selection. Drag a media thumbnail to export it; text and padding do not start exports. Press Delete or `⌘Delete`, or right-click a selected entry and choose **Delete…**, to delete the selection. The confirmation counts the screenshots and recordings inside the selected entries.

<details markdown="1" id="manage-history-storage">
<summary>Manage history storage</summary>

History keeps captures for 30 days by default, with a 5 GB storage limit. Open **History Storage** in the history window's toolbar to see disk usage and change these limits. If you have not chosen a retention period, it follows the current app default.

Snap-O removes the oldest captures when either limit is reached. All devices in an entry are removed together. Captures that are recording or in use are kept. The newest capture is kept for 24 hours if it exceeds the storage limit, so usage can temporarily exceed the limit.

To remove a group, open it and choose **Delete Capture**. **Clear History…** removes all entries that are no longer recording or in use. Close other viewers first if a capture cannot be deleted. Snap-O asks for confirmation before applying storage settings that remove older captures.

</details>

## Keyboard shortcuts

| Action                    | Shortcut |
|---------------------------|----------|
| New screenshot            | `⇧⌘S`    |
| Start / stop recording    | `⇧⌘V`    |
| Start live preview        | `⇧⌘L`    |
| Leave capture review      | `Esc`    |
| Open Capture History      | `⌘Y`     |
| Open Device Manager       | `⇧⌘M`    |
| Save as                   | `⌘S`     |
| Copy image to clipboard   | `⌘C`     |
| Previous device           | `⌘[`     |
| Next device               | `⌘]`     |
| Show / hide Capture       | `⌥⌘C`    |

These device shortcuts act on the selected device while Live Preview is visible.
They also work when the control bar is hidden.

| Device action             | Shortcut |
|---------------------------|----------|
| Back                      | `⇧⌘B`    |
| Home                      | `⇧⌘H`    |
| Recent apps               | `⇧⌘W`    |
| Power / wake              | `⇧⌘P`    |
| Volume up                 | `⇧⌘U`    |
| Volume down               | `⇧⌘D`    |
| Rotate device left        | `⌘L`     |
| Rotate device right       | `⌘R`     |
