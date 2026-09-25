# Device video protocol, version 1

This private contract connects the bundled Android helper and macOS app. Both ship together.
It does not change Network, Tweaks, keyboard, or clipboard protocol versions.

The Mac starts `com.openai.snapo.video.Main` through ADB `exec` and `app_process`.
The sole argument is the temporary helper directory. The helper removes its JAR and directory
before streaming. Diagnostics use stderr; stdout contains only this binary protocol.

All integers are unsigned and big-endian. Timestamps must fit a signed 64-bit integer.
The stream starts with four bytes: `53 4e 56 31` (`SNV1`). Unknown versions are rejected.

| Packet | Layout after the one-byte type |
| --- | --- |
| `1`: display | width, height, density DPI, rotation; four 32-bit integers |
| `2`: AVC access unit | flags: 32 bits; presentation timestamp in microseconds: 64 bits; payload length: 32 bits; payload bytes |

Dimensions must be 2–8192, density 1–4096, and rotation 0–3. Payloads are at most 16 MiB.
Flags are MediaCodec's keyframe (1), codec configuration (2), and end-of-stream (4) bits.
Payloads use AVC Annex B start codes. A display packet and codec configuration precede frames.
Each output buffer is one access unit. The Mac preserves encoder timestamps and converts
NAL start codes to lengths for Core Media. It does not infer frame boundaries or frame rate.
A display change restarts the encoder and emits new display metadata and configuration.

The reverse channel accepts single-byte commands: `1` requests a keyframe; `2` stops.
A keyframe request also reattaches the display mirror so an idle screen submits a fresh image.
It preserves the encoder and its timestamps.
EOF also stops the helper. There are no acknowledgments, installed APKs, or listening sockets.
Subscribers wait for a keyframe before receiving dependent frames. Connection startup has
an eight-second deadline; a stopped or malformed stream fails its subscribers explicitly.

Validation includes parser bounds, native MP4 timing and disconnect recovery, independent
preview/recording ownership, and physical-device startup. Device tests must also cover
rotation, repeated start/stop, input during recording, and supported Android/OEM versions.
