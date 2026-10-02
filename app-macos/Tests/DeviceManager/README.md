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
   startup progress (Starting, Connecting, Booting). Confirm Open becomes available
   during boot once the emulator is discovered, and double-click opens the same preview.
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
8. Quit Snap-O. Confirm its AndroidHostService process exits. Running emulators
   should remain available to other tools.

The service accepts only the containing app's designated signing requirement
and the same user. Emulator operations accept known AVD identifiers. ADB startup
accepts only settings for finding adb and uses fixed command arguments.
It has no login item, daemon, or public listening port.
The app uses its native ADB client for device discovery, boot checks, and Live Preview.
The helper talks directly to emulator consoles for AVD identity and shutdown. It reads
`~/.emulator_console_auth_token` and verifies the AVD path on the same connection
before sending `kill`. It does not expose the token to the app.
Device tracking requests ADB startup once per outage. The helper starts ADB only
when connecting to `127.0.0.1:5037` is refused. A listening endpoint, including a
tunnel, is left alone. Timeouts and other probe errors do not trigger startup.
The helper checks again before launching, uses a five-second command timeout,
and verifies that a listener appeared. It never sends `kill-server`.
A successful device list, including an empty list, rearms recovery for the next
outage. If startup fails, starting ADB manually lets Snap-O reconnect automatically.
ADB startup is independent of the Emulator package and AVD inventory.
The helper also uses SDK adb commands to read emulator display configuration.

### ADB executable discovery

The Mac app checks these locations in order:

1. `SNAPO_ADB`, if set. A full path, `~/` path, or command name from `PATH` is
   accepted. An invalid override reports an error without falling back.
2. `ANDROID_HOME/platform-tools/adb`.
3. `ANDROID_SDK_ROOT/platform-tools/adb`.
4. `~/Library/Android/sdk/platform-tools/adb`.
5. `adb` in the inherited `PATH`.
6. `/opt/homebrew/bin/adb` and `/usr/local/bin/adb`.

No shell is launched and no shell startup files are read. Paths containing spaces
are passed directly to the process API. The app forwards only these four discovery
variables to the helper. Startup always targets the app's local endpoint, even if
inherited ADB server variables point elsewhere. A custom wrapper must honor that
endpoint. `SNAPO_ADB` never forces startup when a listener already exists.

Finder launches do not inherit variables set only in `.zshrc` or `.zprofile`.
To use a custom location, quit Snap-O and launch its executable from Terminal:

```sh
SNAPO_ADB="/custom/platform-tools/adb" /Applications/Snap-O.app/Contents/MacOS/Snap-O
```

For Finder launches in the current login session, set the launch environment before
reopening the app:

```sh
launchctl setenv SNAPO_ADB "/custom/platform-tools/adb"
```

Remove that override with `launchctl unsetenv SNAPO_ADB`.
Emulator SDK discovery still checks `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and
`~/Library/Android/sdk`.
AVDs use the SDK's standard discovery paths. This version does not install SDK
packages or create or edit AVDs. Delete moves stopped AVDs and their configuration
to Trash. Emulator logs are written to `~/Library/Logs/Snap-O/Emulators`.

Before a release, also run the signing and notarization checks in
[release/README.md](../../../release/README.md). A development-signed smoke test
does not verify notarization or distribution policy.
