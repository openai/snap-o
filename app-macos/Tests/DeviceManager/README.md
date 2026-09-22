# Device Manager checks

Run `bash app-macos/Tests/DeviceManager/test.sh` from the repository root.
Each test checks one behavior. The suite covers connected-first ordering,
duplicate emulator rows, safe deletion, stale locks, console authentication,
wrong-emulator shutdown, and console deadlines. Fixtures never touch installed AVDs.
Native ADB transport reuse and timeout tests live in
`Snap-OTests/Device/ADBDiscoveryTimeoutTests.swift`.

## Signed app smoke test

Build the Release app and bundled service with an Apple Development identity:

```sh
DEVICE_MANAGER_SIGNING_IDENTITY='Apple Development: Your Name (CERTIFICATE_ID)' \
  bash app-macos/Tests/DeviceManager/build-sandbox-app.sh /tmp/snapo-device-manager
open /tmp/snapo-device-manager/Snap-O.app
```

Use an identity reported by `security find-identity -v -p codesigning`.
The script verifies signatures, sandbox entitlements, and the bundled service identity.
It uses a separate app identifier, `com.openai.snapo.device-manager-test`.
It runs no emulator commands and changes no AVDs. Quit this test app before rebuilding.
Set `SNAPO_TEST_DERIVED_DATA` to reuse an existing build cache.
The script defaults to Release. Use `SNAPO_TEST_CONFIGURATION=Debug` for a Debug
build, with a separate output directory.

The following checks exercise the production service through the normal UI:

1. Open the test app. Confirm the capture title's ellipsis opens Device Manager.
2. Confirm configured AVDs appear without a separate helper installation.
3. Open Device → Device Manager. Start an existing AVD. Confirm the row shows
   startup progress (Starting, Connecting, Booting) until Open becomes available.
   Confirm Start preserves the current Capture selection and window focus.
   Click Open and confirm Capture selects that emulator in Live Preview and gains focus.
4. Stop it, then cold boot it. Also cold boot a running emulator. Confirm Cold Boot
   shows startup progress without selecting the emulator or focusing Capture.
5. Check that rows show screenshots, or mirrored frames from active Live Preview.
   Double-click a thumbnail: running devices should open; stopped emulators should start.
   Stop a disposable AVD and check Delete confirmation and moving its files to Trash.
6. Start an emulator outside Snap-O. Confirm the window observes it.
7. Connect a physical device. Confirm it appears above offline emulators, Open
   selects it in Live Preview, and unplugging it removes its row. Physical devices
   must have no emulator lifecycle controls.
8. Quit Snap-O. Confirm its EmulatorService process exits. Running emulators
   should remain available to other tools.

The service accepts only the containing app's designated signing requirement
and the same user. Its XPC methods accept known AVD identifiers, not executable
paths or command lines. It has no login item, daemon, or public listening port.
The app uses its native ADB client for device discovery, boot checks, and Live Preview.
The helper talks directly to emulator consoles for AVD identity and shutdown. It reads
`~/.emulator_console_auth_token` and verifies the AVD path on the same connection
before sending `kill`. It does not expose the token to the app.
The SDK's adb executable is used only for `start-server`, when the native client
cannot reach the server. A working server does not require the SDK adb executable.

SDK discovery checks ANDROID_HOME, ANDROID_SDK_ROOT, and ~/Library/Android/sdk.
Finder-launched apps do not inherit variables from shell startup files.
AVDs use the SDK's standard discovery paths. This version does not install SDK
packages or create or edit AVDs. Delete moves stopped AVDs and their configuration
to Trash. Emulator logs are written to `~/Library/Logs/Snap-O/Emulators`.

Before a release, also run the signing and notarization checks in
[release/README.md](../../../release/README.md). A development-signed smoke test
does not verify notarization or distribution policy.
