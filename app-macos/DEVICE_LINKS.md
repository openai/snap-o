# Device links

Open a connected device in Snap-O Live Preview by its ADB serial:

```sh
open 'snapo://open?serial=emulator-5554'
open 'snapo://open?serial=PHONE_SERIAL'
```

Open an installed Android Virtual Device (AVD) by name:

```sh
open 'snapo://open?avd=Pixel_8_API_35&start=true'
```

Snap-O reuses a running or starting emulator. With `start=true`, it starts a
stopped emulator and opens Live Preview as soon as it connects. Preview frames
can appear while Android is still booting. The titlebar shows the target device
name. Startup progress appears under the spinning Snap-O icon until the preview
is ready. Omit `start` or use `start=false` to require an emulator that is already
running or starting.
The request times out after three minutes. Cancel stops waiting; it does not
stop an emulator that has already started.

The Live Preview toolbar device picker includes booting emulators before their
first frame arrives. You can switch to a ready device and return to the booting
emulator later. A new choice from a link, Device Manager, or the toolbar replaces
the previous request without stopping its emulator. If the selected device
disconnects, Live Preview waits for it. Another device becoming ready does not
change the selection.

Use AVD names for emulator links and ADB serials for physical device links.
AVD names remain useful across restarts; an `emulator-5554` serial can belong
to a different AVD after restarting. Names and serials are case-sensitive.
Percent-encode query values when constructing links.

These commands also work from a local agent or script on the Mac running
Snap-O. The shell's `open` command submits the URL; its exit status does not
report whether the emulator booted. Snap-O displays progress and errors.

## Accepted parameters

Each link must contain exactly one nonempty `serial` or `avd` parameter.
Only AVD links accept `start`, whose value must be `true` or `false`.
Unknown or repeated parameters, fragments, credentials, and nonempty paths
are rejected. A single trailing slash is allowed.

Links select connected devices or installed AVDs only. They cannot create an
AVD, connect to an ADB server, run arbitrary commands, pass emulator arguments,
delete data, or export captures. Websites and other apps can invoke these
links, including starting an installed emulator when `start=true` is present.
Repeated requests reuse the pending operation and the existing workspace.
