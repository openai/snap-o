package com.openai.snapo.video;

import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.view.Surface;

import java.io.DataOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicBoolean;

/** A session-scoped AVC stream under the ADB shell identity. */
public final class Main {
    private static final int MAGIC = 0x534e5631;
    private static final int MAX_PACKET = 16 * 1024 * 1024;
    private static final AtomicBoolean keyFrameRequested = new AtomicBoolean();
    private static final DataOutputStream output = new DataOutputStream(new FileOutputStream(FileDescriptor.out));

    public static void main(String[] args) {
        System.setOut(System.err);
        try {
            if (args.length != 1) throw new IllegalArgumentException("Expected temporary directory");
            File directory = new File(args[0]);
            if (!new File(directory, "helper.jar").delete() || !directory.delete()) {
                throw new IOException("Cannot remove temporary helper");
            }
            Looper.prepare();
            output.writeInt(MAGIC);
            output.flush();
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
            Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object global = globalClass.getMethod("getInstance").invoke(null);
            while (true) capture(global);
        } catch (Exception error) {
            // Exception messages from framework services can contain private display metadata.
            System.err.println("Snap-O video capture failed: " + error.getClass().getSimpleName());
            System.exit(1);
        }
    }

    private static int field(Object info, String name) throws Exception {
        return info.getClass().getField(name).getInt(info);
    }

    private static Object displayInfo(Object global) throws Exception {
        Object info = global.getClass().getMethod("getDisplayInfo", int.class).invoke(global, 0);
        if (info == null) throw new IOException("Display unavailable");
        return info;
    }

    private static void capture(Object global) throws Exception {
        Object info = displayInfo(global);
        int width = field(info, "logicalWidth") & ~1;
        int height = field(info, "logicalHeight") & ~1;
        int rotation = field(info, "rotation");
        if (width < 2 || height < 2 || width > 8192 || height > 8192) throw new IOException("Invalid display size");
        MediaCodec encoder = MediaCodec.createEncoderByType("video/avc");
        Surface surface = null;
        AutoCloseable mirror = null;
        boolean started = false;
        try {
            MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 16_000_000);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
            format.setFloat("max-fps-to-encoder", 60);
            // Baseline excludes reordered frames, so presentation timestamps also define decode order.
            format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            surface = encoder.createInputSurface();
            mirror = mirror(surface, width, height, info);
            encoder.start();
            started = true;
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
