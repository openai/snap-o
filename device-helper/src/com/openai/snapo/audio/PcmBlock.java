package com.openai.snapo.audio;

/** A block of samples on the Android monotonic clock. */
final class PcmBlock {
    static final int SAMPLE_RATE = 48000;
    static final int MAX_FRAMES = 960;
    final int channels;
    final short[] samples;
    long startNanos;
    int frames;
    int consumed;

    PcmBlock(int channels) {
        this.channels = channels;
        samples = new short[MAX_FRAMES * channels];
    }

    void reset(long startNanos, int frames) {
        this.startNanos = startNanos;
        this.frames = frames;
        consumed = 0;
    }

    void writeStereo(byte[] output) {
        for (int frame = 0; frame < frames; frame++) {
            int sample = frame * channels;
            write(output, frame * 4, samples[sample]);
            write(output, frame * 4 + 2, samples[sample + channels - 1]);
        }
    }

    /** Returns true when the end of this playback block still needs microphone samples. */
    boolean mixMicrophone(PcmBlock mic, byte[] output) {
        long offset = Math.round((mic.startNanos - startNanos) * (SAMPLE_RATE / 1e9));
        int first = (int) Math.max(mic.consumed, Math.min(mic.frames, -offset));
        int end = (int) Math.max(first, Math.min(mic.frames, frames - offset));
        for (int index = first; index < end; index++) {
            int frame = (int) (offset + index);
            int micSample = mic.samples[index];
            write(output, frame * 4, samples[frame * 2] + micSample);
            write(output, frame * 4 + 2, samples[frame * 2 + 1] + micSample);
        }
        mic.consumed = end;
        return end == mic.frames && offset + mic.frames < frames;
    }

    static long frameNanos(long frames) {
        return frames / SAMPLE_RATE * 1000000000L + frames % SAMPLE_RATE * 1000000000L / SAMPLE_RATE;
    }

    private static void write(byte[] output, int index, int value) {
        int sample = Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, value));
        output[index] = (byte) sample;
        output[index + 1] = (byte) (sample >> 8);
    }
}
