package com.openai.snapo.audio;

import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioRecordingConfiguration;

import java.io.DataOutputStream;
import java.io.IOException;
import java.util.ArrayDeque;
import java.util.List;

/** Reports changes in Android's mic-sharing policy without interrupting the video. */
final class MicrophoneStatus extends AudioManager.AudioRecordingCallback implements AutoCloseable {
    private final AudioRecord recorder;
    private final ArrayDeque<Boolean> changes = new ArrayDeque<>();
    private Boolean silenced;

    MicrophoneStatus(AudioRecord recorder) {
        this.recorder = recorder;
        recorder.registerAudioRecordingCallback(Runnable::run, this);
        synchronized (this) {
            update(recorder.getActiveRecordingConfiguration());
        }
    }

    @Override public synchronized void onRecordingConfigChanged(List<AudioRecordingConfiguration> configs) {
        for (AudioRecordingConfiguration config : configs) update(config);
    }

    private void update(AudioRecordingConfiguration config) {
        if (config == null) return;
        boolean value = config.isClientSilenced();
        if (silenced == null || silenced != value) {
            silenced = value;
            changes.add(value);
        }
    }

    synchronized void writeChanges(DataOutputStream output) throws IOException {
        while (!changes.isEmpty()) {
            output.writeByte(3);
            output.writeByte(changes.remove() ? 1 : 0);
        }
    }

    @Override public void close() {
        recorder.unregisterAudioRecordingCallback(this);
    }
}
