# Device audio

The Mac starts the bundled device helper over ADB shell v2 with one flag per selected source.
The flags can appear in either order. When both sources are off, the Mac skips the audio helper.

| Command | Sources |
| --- | --- |
| `audio --playback` | Eligible Android playback. |
| `audio --microphone` | The input Android routes to the device microphone recorder. |
| `audio --playback --microphone` | Playback mixed with the device microphone on the same clock. |

After the helper build ID, stdout begins with the four ASCII bytes `SNA1`.
Version 1 uses interleaved stereo PCM at 48,000 frames per second. Each frame contains a signed little-endian 16-bit left sample followed by a right sample.

Packet headers use big-endian integers. The first byte identifies the packet.

| Type | Payload |
| --- | --- |
| `1`: samples | Unsigned 64-bit monotonic timestamp in microseconds, unsigned 16-bit frame count, then four bytes per frame. The timestamp identifies the first frame. The frame count is 1 through 960. |
| `2`: failure | One unsigned byte. Code 1 means the Android version is unsupported. Code 2 means playback setup failed. Code 3 means reading samples failed. Code 4 means microphone setup failed. |
| `3`: microphone status | One unsigned byte. Android reports 0 when it grants mic input and 1 when its capture policy silences the recorder. Mic modes send the initial known state and any changes. |

The helper opens only the selected sources on Android 13 or newer. Android applies the playing app’s capture policy. The microphone uses the Android `MIC` source with nonexclusive capture. Mic-only audio is present on both stereo channels. Combined capture adds each microphone sample to both playback channels and clips the sum to the signed 16-bit range. The Mac closes the connection when recording ends. Android releases the sources when their owner exits.
