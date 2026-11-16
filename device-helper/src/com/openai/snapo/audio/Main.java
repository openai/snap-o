package com.openai.snapo.audio;

import android.app.Application;
import android.app.Instrumentation;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Looper;
import android.os.Process;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Streams the Android audio sources selected for one screen recording. */
public final class Main {
    private static final int MAGIC = 0x534e4131; // SNA1

    public static void main(String[] args) throws IOException {
        DataOutputStream output = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(FileDescriptor.out)));
        System.setOut(System.err);
        output.writeInt(MAGIC);
        output.flush();
        if (Build.VERSION.SDK_INT < 33) {
            writeFailure(output, 1);
            return;
        }
        int failure = 2;
        try {
            if (args.length == 0) throw new IllegalArgumentException("Select an audio source");
            boolean playback = false;
            boolean microphone = false;
            for (String option : args) {
                switch (option) {
                    case "--playback": playback = true; break;
                    case "--microphone": microphone = true; break;
                    default: throw new IllegalArgumentException("Unknown audio option: " + option);
                }
            }
            Looper.prepareMainLooper();
            Context shell = shellContext();
            try (PlaybackPolicy policy = playback ? new PlaybackPolicy(shell) : null;
                 PcmInput device = playback ? new PcmInput(policy.recorder(), 2) : null) {
                failure = 4;
                try (PcmInput mic = microphone ? microphone(shell) : null;
                     MicrophoneStatus status = microphone ? new MicrophoneStatus(mic.recorder) : null) {
                    failure = 3;
                    stream(device, mic, status, output);
                }
            }
        } catch (Exception error) {
            writeFailure(output, failure);
        }
    }

    private static PcmInput microphone(Context shell) {
        AudioFormat format = new AudioFormat.Builder().setSampleRate(PcmBlock.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
        AudioRecord recorder = new AudioRecord.Builder().setContext(shell).setAudioFormat(format)
                .setAudioSource(MediaRecorder.AudioSource.MIC).setPrivacySensitive(false).build();
        return new PcmInput(recorder, 1);
    }

    private static final class PlaybackPolicy implements AutoCloseable {
        private final Class<?> mixType = Class.forName("android.media.audiopolicy.AudioMix");
        private final Class<?> policyType = Class.forName("android.media.audiopolicy.AudioPolicy");
        private final AudioManager manager;
        private final Object mix;
        private final Object policy;
        private final Method unregister;

        PlaybackPolicy(Context shell) throws Exception {
            mix = playbackMix(mixType);
            Class<?> builderType = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");
            Object builder = builderType.getConstructor(Context.class).newInstance(shell);
            builderType.getMethod("addMix", mixType).invoke(builder, mix);
            policy = builderType.getMethod("build").invoke(builder);
            manager = shell.getSystemService(AudioManager.class);
            unregister = AudioManager.class.getMethod("unregisterAudioPolicy", policyType);
            int status = (int) AudioManager.class.getMethod("registerAudioPolicy", policyType).invoke(manager, policy);
            if (status != 0) throw new IllegalStateException("Could not register playback capture");
        }

        AudioRecord recorder() throws Exception {
            return (AudioRecord) policyType.getMethod("createAudioRecordSink", mixType).invoke(policy, mix);
        }

        @Override public void close() throws Exception {
            unregister.invoke(manager, policy);
        }
    }

    private static Context shellContext() throws Exception {
        Class<?> threadType = Class.forName("android.app.ActivityThread");
        Object thread = threadType.getMethod("systemMain").invoke(null);
        Context system = (Context) threadType.getMethod("getSystemContext").invoke(thread);
        Context shell = new ContextWrapper(system.createPackageContext("com.android.shell", 0)) {
            private final AttributionSource attribution = new AttributionSource.Builder(Process.myUid())
                    .setPackageName("com.android.shell").build();
            @Override public String getOpPackageName() { return "com.android.shell"; }
            @Override public AttributionSource getAttributionSource() { return attribution; }
        };
        // AudioPolicy creates its recorder using the process application's attribution.
        Field application = threadType.getDeclaredField("mInitialApplication");
        application.setAccessible(true);
        application.set(thread, Instrumentation.newApplication(Application.class, shell));
        return shell;
    }

    private static Object playbackMix(Class<?> mixType) throws Exception {
        Class<?> ruleType = Class.forName("android.media.audiopolicy.AudioMixingRule");
        Class<?> ruleBuilderType = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
        Object rules = ruleBuilderType.getConstructor().newInstance();
        Method addUsage = ruleBuilderType.getMethod("addRule", AudioAttributes.class, int.class);
        int matchUsage = ruleType.getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null);
        for (int usage : new int[]{AudioAttributes.USAGE_UNKNOWN, AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_GAME,
                AudioAttributes.USAGE_ASSISTANT, AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE,
                AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY, AudioAttributes.USAGE_ASSISTANCE_SONIFICATION,
                AudioAttributes.USAGE_ALARM, AudioAttributes.USAGE_NOTIFICATION, AudioAttributes.USAGE_NOTIFICATION_EVENT,
                AudioAttributes.USAGE_NOTIFICATION_RINGTONE, AudioAttributes.USAGE_VOICE_COMMUNICATION,
                AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING}) {
            addUsage.invoke(rules, new AudioAttributes.Builder().setUsage(usage).build(), matchUsage);
        }
        ruleBuilderType.getMethod("voiceCommunicationCaptureAllowed", boolean.class).invoke(rules, true);
        Object rule = ruleBuilderType.getMethod("build").invoke(rules);
        Class<?> builderType = Class.forName("android.media.audiopolicy.AudioMix$Builder");
        Object builder = builderType.getConstructor(ruleType).newInstance(rule);
        AudioFormat format = new AudioFormat.Builder().setSampleRate(PcmBlock.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
        builderType.getMethod("setFormat", AudioFormat.class).invoke(builder, format);
        builderType.getMethod("setRouteFlags", int.class).invoke(builder, mixType.getField("ROUTE_FLAG_LOOP_BACK_RENDER").getInt(null));
        return builderType.getMethod("build").invoke(builder);
    }

    private static void stream(PcmInput playback, PcmInput mic, MicrophoneStatus status, DataOutputStream output) throws IOException {
        PcmInput primary = playback != null ? playback : mic;
        PcmBlock block = primary.block;
        byte[] stereo = new byte[PcmBlock.MAX_FRAMES * 4];
        while (true) {
            primary.read();
            block.writeStereo(stereo);
            if (playback != null && mic != null) {
                do {
                    if (mic.block.consumed == mic.block.frames) mic.read();
                } while (block.mixMicrophone(mic.block, stereo));
            }
            if (status != null) status.writeChanges(output);
            output.writeByte(1);
            output.writeLong(block.startNanos / 1000);
            output.writeShort(block.frames);
            output.write(stereo, 0, block.frames * 4);
            output.flush();
        }
    }

    private static void writeFailure(DataOutputStream output, int reason) throws IOException {
        output.writeByte(2);
        output.writeByte(reason);
        output.flush();
    }
}
