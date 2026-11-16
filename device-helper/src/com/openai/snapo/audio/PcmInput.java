package com.openai.snapo.audio;

import android.media.AudioRecord;
import android.media.AudioTimestamp;

/** Keeps the frame position and timestamp for one Android recording source. */
final class PcmInput implements AutoCloseable {
    final AudioRecord recorder;
    final PcmBlock block;
    private final AudioTimestamp timestamp = new AudioTimestamp();
    private long framesRead;
    private long originNanos;
    private long previousEndNanos;

    PcmInput(AudioRecord recorder, int channels) {
        if (recorder == null) throw new IllegalStateException("Missing audio recorder");
        this.recorder = recorder;
        block = new PcmBlock(channels);
        try {
            recorder.startRecording();
            if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                throw new IllegalStateException("Audio recorder did not start");
            }
        } catch (RuntimeException error) {
            recorder.release();
            throw error;
        }
    }

    void read() {
        int count = recorder.read(block.samples, 0, block.samples.length, AudioRecord.READ_BLOCKING);
        if (count <= 0 || count % block.channels != 0) throw new IllegalStateException("Invalid PCM read");
        int frames = count / block.channels;
        if (recorder.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
            originNanos = timestamp.nanoTime - PcmBlock.frameNanos(timestamp.framePosition);
        } else if (framesRead == 0) {
            originNanos = System.nanoTime() - PcmBlock.frameNanos(frames);
        }
        long start = Math.max(previousEndNanos, originNanos + PcmBlock.frameNanos(framesRead));
        block.reset(start, frames);
        previousEndNanos = start + PcmBlock.frameNanos(frames);
        framesRead += frames;
    }

    @Override public void close() {
        recorder.release();
    }
}
