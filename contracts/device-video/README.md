# Device video protocol, version 1

This private contract connects the bundled Android helper and macOS app. Both ship together.
It does not change Network, Tweaks, keyboard, or clipboard protocol versions.

The Mac starts `com.openai.snapo.video.Main` through ADB `shell,v2,raw:` and `app_process`.
Shell v2 is available from Android 7 (API 24), the helper's minimum API level.
The Mac unwraps stdout packets and wraps control bytes in stdin packets. Shell packet lengths
are little-endian. Stderr is discarded; exit status or a truncated packet ends the stream.
Shell packet boundaries are independent of the video packets below.
The first argument is the temporary helper directory. An optional `rgba-fallback` argument
allows compressed RGBA if AVC encoder startup fails. Every device tries AVC first.
Fallback handles missing encoders, unsupported capabilities or configuration, and permanent
codec failures during encoder startup. Resource exhaustion, reclaimed codecs, transient or
recoverable codec errors, and display, mirror, transport, or streaming failures do not trigger it.
Once selected, RGBA remains active for the session, including display changes.
The helper removes its JAR and directory
before streaming. Stdout contains only this binary protocol, including structured failures.
Framework exception messages are never sent because they can contain private display metadata.

All integers are big-endian and unsigned except the signed codec error.
Timestamps must fit a signed 64-bit integer.
The stream starts with four bytes: `53 4e 56 31` (`SNV1`). Unknown versions are rejected.

| Packet | Layout after the one-byte type |
| --- | --- |
| `1`: display | width, height, density DPI, rotation; four 32-bit integers |
| `2`: AVC access unit | flags: 32 bits; presentation timestamp in microseconds: 64 bits; payload length: 32 bits; payload bytes |
| `3`: failure | stage: 8 bits; retryable: 8 bits (0 or 1); codec error: signed 32 bits (0 if unavailable) |
| `4`: RGBA frame | width, height: 32 bits each; timestamp in microseconds: 64 bits; compressed length: 32 bits; zlib payload |

Failure stages are setup (1), display lookup (2), encoder selection (3), capabilities (4),
configuration (5), input surface (6), display mirror (7), encoder start (8), streaming (9), and image capture (10).
A failure ends the stream. The Mac shows its stage and stops automatic retries when retryable is 0.
Codec failures are retryable only when Android marks them transient or recoverable.
Other display-lookup and streaming failures may retry; other startup failures require an explicit retry.
The error packet contains no strings or captured content. It may follow the header immediately.

Packet 3 is an additive terminal diagnostic; the version remains 1. Existing clients reject it
as an unknown packet and stop the stream. New clients still handle older helpers that close
without a failure packet. The bundled helper and Mac client ship together.
Packet 4 is opt-in through `rgba-fallback`; callers passing only a directory still receive AVC or a failure.
The Mac client and bundled helper must be updated together to use this argument.

Dimensions must be 2–8192, density 1–4096, and rotation 0–3. Payloads are at most 16 MiB.
Flags are MediaCodec's keyframe (1), codec configuration (2), and end-of-stream (4) bits.
Payloads use AVC Annex B start codes. A display packet and codec configuration precede frames.
Each output buffer is one access unit. The Mac preserves encoder timestamps and converts
NAL start codes to lengths for Core Media. It does not infer frame boundaries or frame rate.
A display change restarts the encoder and emits new display metadata and configuration.
The helper caps its 16 Mbps and 60 fps targets to the selected encoder's advertised limits.
It requires support for the display size, Surface input, and a Baseline AVC profile.
Unsupported configurations fail before encoding; this protocol does not resize the display.

RGBA mode mirrors into an `ImageReader`, bypassing the device's video encoder. It copies
RGBA bytes into tightly packed rows and compresses each frame independently with zlib level 1.
Both compressed and expanded payloads are limited to 16 MiB. Expanded bytes must equal
width × height × 4, and dimensions must match the preceding display packet. Trailing compressed
bytes, invalid checksums, and incomplete frames are rejected. Capture is capped at about 30 fps.
The Mac expands RGBA and converts it into BGRA pixel buffers. Recordings encode H.264 on the Mac.
A display change recreates the reader and sends new display metadata before the next frame.

The reverse channel accepts single-byte commands: `1` requests a keyframe; `2` stops.
A keyframe request also reattaches the display mirror so an idle screen submits a fresh image.
It preserves the encoder and its timestamps.
In RGBA mode, command `1` resends the latest image with a new monotonic timestamp.
Every RGBA frame is independent, so a new subscriber can immediately use the cached frame.
EOF also stops the helper. There are no acknowledgments, installed APKs, or listening sockets.
Subscribers wait for a keyframe before receiving dependent frames. Connection startup has
an eight-second deadline; a stopped or malformed stream fails its subscribers explicitly.

Validation includes parser bounds, native MP4 timing and disconnect recovery, independent
preview/recording ownership, and physical-device startup. Device tests must also cover
rotation, repeated start/stop, input during recording, and supported Android/OEM versions.
