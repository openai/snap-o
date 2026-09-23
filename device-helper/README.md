# Device helper

Snap-O bundles `snapo-device-helper.jar` for clipboard sync and keyboard input during Live Preview.
It runs through `app_process` as the ADB shell. No APK, root access, or app dependency is required.
Emulators continue using their existing gRPC clipboard service.
Keyboard input uses the helper on both emulators and physical devices.

Each session creates a private temporary directory under `/data/local/tmp`, writes a read-only JAR,
and starts it over a bidirectional ADB `exec` connection. The helper removes its JAR and directory
after Android loads it; the launch script also cleans up failed starts. Closing the connection
ends the helper. There is no network listener or persistent service.

In clipboard mode, the helper only reads and writes plain text. It registers an Android clipboard listener and sends
changes to the Mac. Host writes suppress their corresponding notification. The desktop shares
initial clipboard handling, limits, and feedback-loop prevention with emulator sync.
It starts the helper only while Live Preview is visible and the saved Sync clipboard setting is on.
On Android 13+, host writes include the same per-clip overlay suppression flag as Android Studio.
This hides the bottom clipboard preview without changing the device's global settings or read-access toasts.

Framework initialization and the `ClipboardManager` constructor use reflection. The clipboard context
uses the shell's operation package so Android can validate its UID. Android or OEM changes may make
these APIs unavailable; Snap-O retries without failing Live Preview. Device testing is required when
changing this boundary. Clipboard text is never included in diagnostics.
The context belongs to the foreground Android user. A user change ends the session on its next
clipboard operation, allowing the desktop to reconnect for the new user.

## Build and validate

Install JDK 17, Android SDK platform 36, and build-tools 36.0.0. Then run:

```sh
python3 device-helper/build.py
python3 device-helper/build.py --check
```

The reproducible JAR is checked in and copied into the macOS app's Resources directory.
Desktop users do not need Java or the Android SDK. Android CI checks that the JAR matches its sources.

To verify on a device, open Live Preview with Sync clipboard enabled. Copy synthetic text in each
direction, then turn sync off and check that further copies stay local. On Android 13+, host writes
should not show the bottom clipboard preview. Android may still show a clipboard read-access toast.

See the [internal clipboard contract](../contracts/device-clipboard/README.md).

## Keyboard input

Keyboard input is on by default. Click the device image to type. Clicking outside the image,
opening a context menu, or Command-dragging an image releases keyboard focus and closes the input connection.
Leaving the app, hiding the preview, or turning keyboard input off also releases focus.
Each preview owns a keyboard controller bound to its device. Only the focused preview in the
active window sends input. The input helper starts on the first keystroke and processes requests in order.

Typing uses Android's virtual keyboard character map. Return, Tab, Delete, and arrow keys work
as device input; Shift extends selections. Escape is forwarded unchanged unless it cancels an active
pointer gesture or unfinished text composition. Characters absent from Android's map are rejected
without inserting part of the text. Later input continues on the same connection.
Use Paste for these characters, including emoji.

With keyboard input on and the preview focused, Command-C copies Android's selected text to the Mac.
Command-V pastes Mac text into Android. These actions work with clipboard sync off. Pasting explicitly
replaces the device clipboard. With keyboard input off, Command-C copies the preview image.
The preview's Copy Image menu item always copies the image.

Validate typing, deletion, selection, Unicode paste, and copy with clipboard sync both on and off.
Verify that changing focus or devices discards queued input. Use synthetic text only.
See the [internal keyboard contract](../contracts/device-keyboard/README.md).
