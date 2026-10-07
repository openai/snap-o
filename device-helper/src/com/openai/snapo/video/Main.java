package com.openai.snapo.video;

import android.graphics.Rect;
import android.graphics.PixelFormat;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.Build;
import android.os.IBinder;
import android.os.Looper;
import android.view.Surface;

import java.io.DataOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.Deflater;

/** A session-scoped display stream under the ADB shell identity. */
public final class Main {
    private static final int MAGIC = 0x534e5631;
    private static final int MAX_PACKET = 16 * 1024 * 1024;
    private static final AtomicBoolean keyFrameRequested = new AtomicBoolean();
    private static final DataOutputStream output = new DataOutputStream(new FileOutputStream(FileDescriptor.out));
    private static Stage stage = Stage.SETUP;

    private enum Stage {
        SETUP(1), DISPLAY(2), ENCODER(3), CAPABILITIES(4), CONFIGURATION(5),
        INPUT_SURFACE(6), MIRROR(7), START(8), STREAM(9), CAPTURE(10);

        final int code;

        Stage(int code) {
            this.code = code;
        }
    }

    public static void main(String[] args) {
        System.setOut(System.err);
        try {
            output.writeInt(MAGIC);
            output.flush();
            if (args.length < 1 || args.length > 2
                    || (args.length == 2 && !args[1].equals("rgba-if-waydroid"))) {
                throw new IllegalArgumentException("Invalid video arguments");
            }
            boolean rgba = args.length == 2 && Build.DEVICE.startsWith("waydroid_");
            File directory = new File(args[0]);
            if (!new File(directory, "helper.jar").delete() || !directory.delete()) {
                throw new IOException("Cannot remove temporary helper");
            }
            Looper.prepare();
            Thread controls = new Thread(() -> {
                try {
                    int command;
                    while ((command = System.in.read()) != -1) {
                        if (command == 1) keyFrameRequested.set(true);
                        else if (command == 2) System.exit(0);
                        else System.exit(1);
                    }
                    System.exit(0);
                } catch (IOException error) {
                    System.exit(1);
                }
            }, "snapo-video-controls");
            controls.setDaemon(true);
            controls.start();
            stage = Stage.DISPLAY;
            Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object global = globalClass.getMethod("getInstance").invoke(null);
            while (true) {
                if (rgba) captureRGBA(global);
                else capture(global);
            }
        } catch (Exception error) {
            reportFailure(error);
            System.exit(1);
        }
    }

    private static void reportFailure(Exception error) {
        Throwable cause = error;
        while (cause instanceof InvocationTargetException && cause.getCause() != null) {
            cause = cause.getCause();
        }
        int codecError = 0;
        boolean retryable = stage == Stage.DISPLAY || stage == Stage.STREAM;
        if (cause instanceof MediaCodec.CodecException) {
            MediaCodec.CodecException codec = (MediaCodec.CodecException) cause;
            codecError = codec.getErrorCode();
            retryable = codec.isTransient() || codec.isRecoverable();
        }
        // Framework exception messages can contain private display metadata.
        try {
            output.writeByte(3);
            output.writeByte(stage.code);
            output.writeByte(retryable ? 1 : 0);
            output.writeInt(codecError);
            output.flush();
        } catch (IOException disconnected) {
            // A disconnected client cannot receive the failure packet.
        }
    }

    private static int field(Object info, String name) throws Exception {
        return info.getClass().getField(name).getInt(info);
    }

    private static void captureRGBA(Object global) throws Exception {
        stage = Stage.DISPLAY;
        Object info = displayInfo(global);
        int width = field(info, "logicalWidth");
        int height = field(info, "logicalHeight");
        int rotation = field(info, "rotation");
        stage = Stage.CAPTURE;
        long byteCount = (long) width * height * 4;
        if (width < 2 || height < 2 || width > 8192 || height > 8192
                || byteCount > MAX_PACKET) throw new IOException("Invalid capture size");
        byte[] pixels = new byte[(int) byteCount];
        byte[] compressed = new byte[(int) byteCount + (int) byteCount / 1000 + 64];
        Deflater deflater = new Deflater(1);
        try (ImageReader reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)) {
            stage = Stage.MIRROR;
            try (AutoCloseable mirror = mirror(reader.getSurface(), width, height, info)) {
                output.writeByte(1);
                output.writeInt(width);
                output.writeInt(height);
                output.writeInt(field(info, "logicalDensityDpi"));
                output.writeInt(rotation);
                output.flush();
                long nextFrame = 0;
                long nextDisplayCheck = 0;
                long lastTimestamp = 0;
                boolean hasFrame = false;
                while (true) {
                    stage = Stage.CAPTURE;
                    long now = android.os.SystemClock.uptimeMillis();
                    if (now >= nextDisplayCheck) {
                        Object current = displayInfo(global);
                        if (field(current, "logicalWidth") != width || field(current, "logicalHeight") != height
                                || field(current, "rotation") != rotation) return;
                        nextDisplayCheck = now + 250;
                    }
                    boolean send = hasFrame && keyFrameRequested.getAndSet(false);
                    long timestamp = System.nanoTime() / 1000;
                    if (now >= nextFrame) {
                        try (Image image = reader.acquireLatestImage()) {
                            if (image != null) {
                                if (image.getWidth() != width || image.getHeight() != height) return;
                                Image.Plane plane = image.getPlanes()[0];
                                if (plane.getPixelStride() != 4) throw new IOException("Unsupported pixel layout");
                                ByteBuffer buffer = plane.getBuffer();
                                int base = buffer.position();
                                for (int y = 0; y < height; y++) {
                                    buffer.position(base + y * plane.getRowStride());
                                    buffer.get(pixels, y * width * 4, width * 4);
                                }
                                timestamp = image.getTimestamp() / 1000;
                                hasFrame = true;
                                send = true;
                                nextFrame = now + 34;
                            }
                        }
                    }
                    if (send) {
                        deflater.reset();
                        deflater.setInput(pixels);
                        deflater.finish();
                        int count = deflater.deflate(compressed);
                        if (!deflater.finished() || count > MAX_PACKET) throw new IOException("Capture packet too large");
                        // A requested repeat must not move recording timestamps backwards.
                        lastTimestamp = Math.max(lastTimestamp + 1, timestamp);
                        output.writeByte(4);
                        output.writeInt(width);
                        output.writeInt(height);
                        output.writeLong(lastTimestamp);
                        output.writeInt(count);
                        output.write(compressed, 0, count);
                        output.flush();
                    }
                    android.os.SystemClock.sleep(2);
                }
            }
        } finally {
            deflater.end();
        }
    }

    private static Object displayInfo(Object global) throws Exception {
        Object info = global.getClass().getMethod("getDisplayInfo", int.class).invoke(global, 0);
        if (info == null) throw new IOException("Display unavailable");
        return info;
    }

    private static void capture(Object global) throws Exception {
        stage = Stage.DISPLAY;
        Object info = displayInfo(global);
        int width = field(info, "logicalWidth") & ~1;
        int height = field(info, "logicalHeight") & ~1;
        int rotation = field(info, "rotation");
        if (width < 2 || height < 2 || width > 8192 || height > 8192) throw new IOException("Invalid display size");
        stage = Stage.ENCODER;
        MediaCodec encoder = MediaCodec.createEncoderByType("video/avc");
        Surface surface = null;
        AutoCloseable mirror = null;
        boolean started = false;
        try {
            stage = Stage.CAPABILITIES;
            MediaFormat format = createFormat(encoder.getCodecInfo(), width, height);
            stage = Stage.CONFIGURATION;
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            stage = Stage.INPUT_SURFACE;
            surface = encoder.createInputSurface();
            stage = Stage.MIRROR;
            mirror = mirror(surface, width, height, info);
            stage = Stage.START;
            encoder.start();
            started = true;
            stage = Stage.STREAM;
            output.writeByte(1);
            output.writeInt(width);
            output.writeInt(height);
            output.writeInt(field(info, "logicalDensityDpi"));
            output.writeInt(rotation);
            output.flush();
            MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
            long nextDisplayCheck = 0;
            while (true) {
                if (keyFrameRequested.getAndSet(false)) {
                    Bundle parameters = new Bundle();
                    parameters.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                    encoder.setParameters(parameters);
                    // An idle display may have exhausted the encoder's repeated frames.
                    // Reattach the mirror to submit its current image without restarting the codec.
                    mirror.close();
                    mirror = mirror(surface, width, height, info);
                }
                int index = encoder.dequeueOutputBuffer(bufferInfo, 20_000);
                if (index >= 0) {
                    try {
                        if (bufferInfo.size > 0) {
                            if (bufferInfo.size > MAX_PACKET) throw new IOException("Video packet too large");
                            ByteBuffer buffer = encoder.getOutputBuffer(index);
                            buffer.position(bufferInfo.offset);
                            buffer.limit(bufferInfo.offset + bufferInfo.size);
                            byte[] bytes = new byte[bufferInfo.size];
                            buffer.get(bytes);
                            output.writeByte(2);
                            output.writeInt(bufferInfo.flags);
                            output.writeLong(bufferInfo.presentationTimeUs);
                            output.writeInt(bytes.length);
                            output.write(bytes);
                            output.flush();
                        }
                    } finally {
                        encoder.releaseOutputBuffer(index, false);
                    }
                }
                long now = android.os.SystemClock.uptimeMillis();
                if (now >= nextDisplayCheck) {
                    Object current = displayInfo(global);
                    if ((field(current, "logicalWidth") & ~1) != width
                            || (field(current, "logicalHeight") & ~1) != height
                            || field(current, "rotation") != rotation) return;
                    nextDisplayCheck = now + 250;
                }
            }
        } finally {
            if (mirror != null) mirror.close();
            if (started) encoder.stop();
            encoder.release();
            if (surface != null) surface.release();
        }
    }

    private static MediaFormat createFormat(MediaCodecInfo info, int width, int height) {
        MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType("video/avc");
        MediaCodecInfo.VideoCapabilities video = capabilities.getVideoCapabilities();
        boolean surfaceInput = false;
        for (int color : capabilities.colorFormats) {
            if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface) surfaceInput = true;
        }
        if (!surfaceInput || video == null || !video.isSizeSupported(width, height)) {
            throw new IllegalArgumentException("Unsupported video input");
        }
        int profile = 0;
        for (MediaCodecInfo.CodecProfileLevel level : capabilities.profileLevels) {
            if (level.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline) {
                profile = level.profile;
                break;
            }
            if (level.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline) profile = level.profile;
        }
        if (profile == 0) throw new IllegalArgumentException("Baseline AVC is unavailable");
        int frameRate = (int) Math.floor(video.getSupportedFrameRatesFor(width, height).clamp(60.0));
        if (frameRate < 1 || !video.areSizeAndRateSupported(width, height, frameRate)) {
            throw new IllegalArgumentException("Unsupported video frame rate");
        }
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, video.getBitrateRange().clamp(16_000_000));
        format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
        format.setFloat("max-fps-to-encoder", frameRate);
        // Baseline excludes reordered frames, so presentation timestamps also define decode order.
        format.setInteger(MediaFormat.KEY_PROFILE, profile);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        if (!capabilities.isFormatSupported(format)) throw new IllegalArgumentException("Unsupported video format");
        return format;
    }

    private static AutoCloseable mirror(Surface surface, int width, int height, Object info) throws Exception {
        try {
            VirtualDisplay display = (VirtualDisplay) Class.forName("android.hardware.display.DisplayManager")
                    .getMethod("createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class)
                    .invoke(null, "Snap-O", width, height, 0, surface);
            return display::release;
        } catch (ReflectiveOperationException unavailable) {
            // Older Android releases expose display mirroring through SurfaceControl instead.
            Class<?> control = Class.forName("android.view.SurfaceControl");
            IBinder token = (IBinder) control.getMethod("createDisplay", String.class, boolean.class)
                    .invoke(null, "Snap-O", false);
            try {
                control.getMethod("openTransaction").invoke(null);
                try {
                    control.getMethod("setDisplaySurface", IBinder.class, Surface.class).invoke(null, token, surface);
                    control.getMethod("setDisplayLayerStack", IBinder.class, int.class)
                            .invoke(null, token, field(info, "layerStack"));
                    control.getMethod("setDisplayProjection", IBinder.class, int.class, Rect.class, Rect.class)
                            .invoke(null, token, 0, new Rect(0, 0, width, height), new Rect(0, 0, width, height));
                } finally {
                    control.getMethod("closeTransaction").invoke(null);
                }
            } catch (Exception error) {
                control.getMethod("destroyDisplay", IBinder.class).invoke(null, token);
                throw error;
            }
            return () -> control.getMethod("destroyDisplay", IBinder.class).invoke(null, token);
        }
    }
}
