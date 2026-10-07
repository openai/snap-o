# Device helper

Snap-O bundles `snapo-device-helper.jar` for clipboard sync, keyboard and pointer input, and physical-device video.
It runs through `app_process` as the ADB shell. No APK, root access, or app dependency is required.
Emulators continue using their existing gRPC clipboard service.
Keyboard input uses the helper on both emulators and physical devices.

Each session creates a private temporary directory under `/data/local/tmp`, writes a read-only JAR,
and starts it over a bidirectional ADB connection: shell v2 for video and pointer input, `exec` for clipboard and keyboard.
The helper removes its JAR and directory
after Android loads it; the launch script also cleans up failed starts. Closing the connection
ends the helper. There is no network listener or persistent service.

In clipboard mode, the helper only reads and writes plain text. It registers an Android clipboard listener and sends
changes to the Mac. Host writes suppress their corresponding notification. The desktop shares
initial clipboard handling, limits, and feedback-loop prevention with emulator sync.
The desktop skips the initial host write when Android already has the same text.
It starts the helper only while Live Preview is visible and the saved Sync clipboard setting is on.
On Android 13+, host writes include the same per-clip overlay suppression flag as Android Studio.
Android uses this flag to hide the bottom clipboard preview without changing global settings or read-access toasts.
Waydroid's host clipboard bridge can discard the flag, so new host writes may still show the preview.

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

## Pointer input

Snap-O prefers a persistent `uinput` virtual touchscreen. When it is unavailable,
pointer input uses a persistent helper calling Android's `InputManager`.
Mouse input also uses this helper. Touch and mouse events remain ordered within
each source; queued moves are coalesced. There is no network acknowledgment per move.
The helper supports up to ten contacts and cancels held contacts on disconnect.
A failed stream never replays a partial gesture on a new connection.

Android's native Show touches dots require the `uinput` path. InputManager injection
bypasses that visualization; enabling Show input touches will not add dots to these events.
The fallback does not draw its own overlay.

See the [internal pointer contract](../contracts/device-pointer/README.md).

## Device video

Physical-device preview and normal recording share one hardware AVC encoder per device.
The Mac decodes preview frames and writes the original compressed samples to MP4.
Every device tries AVC first. Missing or unsupported encoders and permanent codec startup failures
fall back to an experimental `ImageReader` path with lossless, zlib-compressed RGBA frames.
Transient, recoverable, resource, display, and transport failures do not select the fallback.
ImageReader bypasses the device video encoder and targets about 30 fps. The Mac converts these frames
for preview and encodes H.264 when recording. This path currently supports frames up to 16 MiB.
Each consumer owns a subscription. Closing a preview does not stop its recording.
The final subscription closes the ADB connection and ends the helper.
Emulators retain gRPC preview and Android file recording. Bug-report recordings retain
Android's overlay writer and temporarily stop preview.

Video uses a separate helper process and connection from keyboard and clipboard input.
It captures the main display at its current resolution, targeting 16 Mbps and 60 fps.
Bitrate and frame rate are capped to the encoder's advertised limits. The helper checks
display size, Surface input, and Baseline AVC support before configuring the encoder.
Actual frame rate and quality depend on the device encoder and transport.
The helper uses framework display-mirroring APIs under the shell identity. These APIs
vary across Android versions and vendors; validate supported devices before release.
It never captures protected surfaces or bypasses Android's secure-content restrictions.
Failures report the capture stage and numeric codec error without framework exception text.
Unsupported configurations stop automatic retries. Transient or recoverable codec failures
retain the Mac client's bounded retry behavior.

The Mac requests a keyframe when a recording joins an existing preview. Packet timestamps
come from the encoder. Slow storage fails the recording instead of silently dropping frames.
A disconnect or format change finalizes the received video and reports the interruption.
Rotating a device currently ends its recording; preview reconnects to the new video format.

See the [internal video contract](../contracts/device-video/README.md).

Automated tests use fake frame sources and recording writers to check independent
preview and recording lifetimes. An RGBA recording test also encodes and decodes a synthetic frame. For a manual
check, use a connected device showing synthetic content. Start recording during
preview, stop recording, and confirm that preview continues and the recording plays.
