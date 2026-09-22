# Device clipboard protocol, version 1

This private protocol connects the macOS app to its bundled Android clipboard helper.
The helper and client ship together. Network and Tweaks protocols, Android libraries, web tools,
and Python CLIs are unchanged and do not consume this protocol.

The transport is a raw, bidirectional ADB `exec` stream. Diagnostics go to stderr, which the
launch command discards. No clipboard contents belong in logs, launch arguments, or temporary files.

The helper first writes a four-byte unsigned big-endian version number (`1`). The client rejects
other versions before enabling sync. Every subsequent message in either direction contains:

| Field | Encoding |
| --- | --- |
| Text byte count | Four-byte unsigned big-endian integer, at most 1,048,576 |
| Text | Exactly that many bytes of valid UTF-8 |

The first helper message is the current clipboard snapshot. An empty message means no supported
text is available. Subsequent messages report changed, nonempty text. The helper reads only the
first item's text, without resolving file URIs or coercing other content. Oversized device text
is treated as unavailable. Host messages replace the Android clipboard with plain text;
empty host messages do nothing. Writes initiated by this helper do not echo back to its client.
On Android 13+, host writes set the `com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY` description extra.
System UI recognizes it for shell clipboard writes and hides the clipboard preview overlay.

Malformed lengths, invalid UTF-8, and incomplete messages terminate the session. EOF terminates
the helper. It removes its temporary JAR and directory immediately after loading, with a launch-script
cleanup trap for failed starts. The desktop cancels pending
socket operations when sync stops and reconnects after transport failure.

The desktop preserves existing Mac clipboard items at startup, including unsupported content.
If its clipboard is empty, it may import the device snapshot. During sync, a newer local copy
takes precedence over a device event still in flight. Empty or unsupported content does not clear
the other clipboard. The same rules apply to emulator sync.

This is a new internal contract starting at version 1. It does not change any published tool API
or require a Network or Tweaks protocol version bump.
