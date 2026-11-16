package com.openai.snapo.audio;

import java.util.Arrays;

public final class PcmBlockTest {
    public static void main(String[] args) {
        byte[] stereo = new byte[16];
        PcmBlock mic = block(1, 0, -32768, 0x1234, 32767);
        mic.writeStereo(stereo);
        expect(stereo, -32768, -32768, 0x1234, 0x1234, 32767, 32767);

        PcmBlock playback = block(2, 100, 1, -1, 2, -2, 3, -3, 4, -4);
        playback.writeStereo(stereo);
        mic = block(1, 99, 99, 10, 20);
        check(playback.mixMicrophone(mic, stereo));
        check(mic.consumed == 3);
        mic = block(1, 102, 30, 40, 50, 60);
        check(!playback.mixMicrophone(mic, stereo));
        check(mic.consumed == 2);
        expect(stereo, 11, 9, 22, 18, 33, 27, 44, 36);

        playback = block(2, 104, 32760, 32000, -32760, -32000);
        playback.writeStereo(stereo);
        mic.samples[3] = -1000;
        check(!playback.mixMicrophone(mic, stereo));
        expect(stereo, 32767, 32050, -32768, -32768);

        playback = block(2, 200, 6, 7, 8, 9);
        playback.writeStereo(stereo);
        mic = block(1, 190, 123);
        check(playback.mixMicrophone(mic, stereo) && mic.consumed == 1);
        mic = block(1, 203, 123);
        check(!playback.mixMicrophone(mic, stereo) && mic.consumed == 0);
        expect(stereo, 6, 7, 8, 9);
        System.out.println("Timestamped PCM mixing tests passed");
    }

    private static PcmBlock block(int channels, int frame, int... values) {
        PcmBlock block = new PcmBlock(channels);
        block.reset(PcmBlock.frameNanos(frame), values.length / channels);
        for (int i = 0; i < values.length; i++) block.samples[i] = (short) values[i];
        return block;
    }

    private static void expect(byte[] stereo, int... values) {
        int[] actual = new int[values.length];
        for (int i = 0; i < actual.length; i++) {
            actual[i] = (short) ((stereo[2 * i] & 0xff) | (stereo[2 * i + 1] << 8));
        }
        if (!Arrays.equals(values, actual)) throw new AssertionError(Arrays.toString(actual));
    }

    private static void check(boolean result) {
        if (!result) throw new AssertionError("Incorrect microphone block boundary");
    }
}
