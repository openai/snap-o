# Device clipboard helper

Snap-O bundles `snapo-device-helper.jar` for physical-device clipboard sync during Live Preview.
It runs through `app_process` as the ADB shell. No APK, root access, or app dependency is required.
Emulators continue using their existing gRPC clipboard service.

Each session creates a private temporary directory under `/data/local/tmp`, writes a read-only JAR,
and starts it over a bidirectional ADB `exec` connection. The helper removes its JAR and directory
after Android loads it; the launch script also cleans up failed starts. Closing the connection
ends the helper. There is no network listener or persistent service.

The helper only reads and writes plain text. It registers an Android clipboard listener and sends
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
