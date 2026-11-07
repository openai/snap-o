# Device pointer protocol, version 1

This new internal contract connects Snap-O to its bundled pointer helper over
ADB shell v2. It does not change existing keyboard, clipboard, video, Network,
or Tweaks protocol versions. No frontend or Python CLI uses this transport.
Both peers ship together; older helpers lack this entry point and fail startup.

The helper runs as shell, removes its temporary JAR after loading, and writes a
four-byte unsigned big-endian version (`1`) when ready. The client rejects other
versions. Subsequent stdout, EOF, or shell exit closes the client connection.

Every request contains five big-endian unsigned 32-bit integers, followed by
`count` coordinate pairs. Each coordinate is an IEEE-754 big-endian float32.

| Field | Values |
| --- | --- |
| Source | 0: touchscreen; 1: mouse |
| Action | 0: down; 1: up; 2: move; 3: cancel |
| Count | 1–10 contacts; mouse requires 1 |
| Width, height | Current display dimensions, each 1–65536 pixels |
| Coordinates | Finite x, y values in display pixels, within those dimensions |

Contact array indices are stable pointer IDs for a gesture. Down introduces
contacts in order; Up removes them in reverse order. All events in one gesture
share the original Android uptime down timestamp. Changed geometry or contact
count cancels the active gesture. Mouse movement without a held button is hover.

The helper injects events asynchronously and sends no per-event reply. This
confirms neither application handling nor drawing. The client serializes writes;
its existing queues coalesce consecutive moves without dropping Down or Up.
Startup is bounded to eight seconds. Shutdown closes the socket and joins pending
writes and the exit reader. Malformed frames and injection failures end the helper;
EOF and failures cancel held contacts. A failed gesture is not replayed; only a
new Down may reconnect. Closing the preview releases the helper.
The launch script ignores SIGHUP so ADB disconnect reaches stdin EOF and allows
the helper to cancel contacts before exiting.

InputManager does not produce Android's native Show touches indicators. The
preferred uinput path remains available for devices that support it.
