# Device keyboard protocol, version 2

This internal protocol connects Live Preview to the bundled device helper's `keyboard` mode.
Both parts ship together. Clipboard mode remains at version 1 with its existing framing.
Network, Tweaks, Android libraries, frontends, and Python CLIs are unchanged.

The transport and temporary-file lifetime match the [clipboard helper](../device-clipboard/README.md).
Text travels only in the ADB stream, never in shell arguments, files, or diagnostics.
The helper begins with a four-byte unsigned big-endian version (`2`). The client rejects other versions.

Every request starts with a four-byte unsigned big-endian command. Text fields contain a four-byte
UTF-8 byte count followed by valid UTF-8, limited to 1,048,576 bytes.

| Command | Payload | Behavior |
| --- | --- | --- |
| 1 | Text | Inject the virtual keyboard's character-map events; reject unmappable text before injecting anything. |
| 2 | Key code, modifier mask (four bytes each) | Inject a complete key press. Accept codes above `KEYCODE_UNKNOWN` through Android's `KeyEvent.getMaxKeyCode()`; allow only the Shift modifier (1). |
| 3 | Text | Set the device clipboard, then inject Paste. Empty text does nothing. |
| 4 | None | Inject Copy, wait up to 500 ms for a clipboard notification, and return its plain text. No change leaves the Mac clipboard untouched. |
| 5 | Key code (four bytes) | Press and hold a key without modifiers. Repeated presses of the same key do nothing. |
| 6 | Key code (four bytes) | Release a held key using its original down time. Releasing an unheld key does nothing. |

While a key remains held, the helper sends one repeated key-down at Android's configured
long-press timeout. It keeps the original down time, sets repeat count to 1, and sets
`FLAG_LONG_PRESS`, matching Android's shell input command. Releasing the key or ending the
session invalidates the delayed event. This fixes held-key behavior without changing version 2 framing.

Every request receives a four-byte status: `0` means complete without text, `1` means a text field
follows, and `2` means the requested typing contains unsupported characters. The client sends one
request at a time. Input injection waits for dispatch to finish before acknowledging the request.
Unsupported text rejects only that request; the client continues sending queued input on the same connection.

The Mac client maps supported keyboard input to Android key codes. The helper validates the range
without maintaining a second list of supported keys.
Commands 5 and 6 accept the same key-code range as command 2. A complete press of an already
held key does nothing. The helper attempts to release every held key before ending the session,
including after malformed requests, out-of-range keys, injection failures, and EOF.
The client closes the socket on cancellation and does not retry input automatically.
Loss of preview focus discards queued requests and copied text still in flight, then releases keys
whose presses were sent. Leaving only the text responder preserves queued device-control events.
A copy result cannot replace
a newer Mac clipboard change. Keyboard input has its own connection and does not require clipboard sync.

Version 2 adds held-key commands. The bundled client requires version 2 because version 1 cannot
hold keys. Old and new pairs reject mismatched versions before sending input. The helper JAR and
Mac client ship together; no published tool API or other protocol number changes.
