package com.openai.snapo.pointer;

import android.os.Looper;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Method;

/** Ordered pointer injection under the shell identity, without per-event network replies. */
public final class Main {
    private static final int VERSION = 1;
    private final Object manager;
    private final Method inject;
    private final Gesture touch = new Gesture(false);
    private final Gesture mouse = new Gesture(true);

    private Main() throws Exception {
        Class<?> type;
        try {
            type = Class.forName("android.hardware.input.InputManagerGlobal");
        } catch (ClassNotFoundException olderAndroid) {
            type = Class.forName("android.hardware.input.InputManager");
        }
        manager = type.getMethod("getInstance").invoke(null);
        inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
    }

    public static void main(String[] args) {
        DataOutputStream output = new DataOutputStream(new FileOutputStream(FileDescriptor.out));
        System.setOut(System.err);
        Main input = null;
        int status = 0;
        try {
            if (args.length != 1) throw new IOException("Invalid arguments");
            Looper.prepare();
            input = new Main();
            File directory = new File(args[0]);
            if (!new File(directory, "helper.jar").delete() || !directory.delete()) {
                throw new IOException("Cannot remove temporary helper");
            }
            output.writeInt(VERSION);
            output.flush();
            input.read(new DataInputStream(System.in));
        } catch (Exception error) {
            // Never include framework exception text in the transport.
            status = 1;
        } finally {
            if (input != null) {
                input.cancel(input.touch);
                input.cancel(input.mouse);
            }
        }
        System.exit(status);
    }

    private void read(DataInputStream input) throws Exception {
        while (true) {
            int source;
            try { source = input.readInt(); } catch (EOFException closed) { return; }
            int action = input.readInt();
            int count = input.readInt();
            int width = input.readInt();
            int height = input.readInt();
            if (source < 0 || source > 1 || action < 0 || action > 3
                    || count < 1 || count > 10 || (source == 1 && count != 1)
                    || width < 1 || width > 65536 || height < 1 || height > 65536) {
                throw new IOException("Invalid pointer frame");
            }
            MotionEvent.PointerCoords[] points = new MotionEvent.PointerCoords[count];
            for (int i = 0; i < count; i++) {
                float x = input.readFloat();
                float y = input.readFloat();
                if (Float.isNaN(x) || Float.isInfinite(x) || Float.isNaN(y) || Float.isInfinite(y)
                        || x < 0 || x >= width || y < 0 || y >= height) {
                    throw new IOException("Invalid pointer position");
                }
                points[i] = new MotionEvent.PointerCoords();
                points[i].x = x;
                points[i].y = y;
                points[i].size = 1;
            }
            Gesture gesture = source == 0 ? touch : mouse;
            if (action == MotionEvent.ACTION_DOWN) {
                cancel(gesture);
                gesture.width = width;
                gesture.height = height;
                gesture.points = points;
                gesture.downTime = SystemClock.uptimeMillis();
                for (int n = 1; n <= count; n++) {
                    send(gesture, n == 1 ? MotionEvent.ACTION_DOWN
                            : MotionEvent.ACTION_POINTER_DOWN | ((n - 1) << MotionEvent.ACTION_POINTER_INDEX_SHIFT), n);
                }
            } else if (gesture.downTime != 0) {
                if (count != gesture.points.length || width != gesture.width || height != gesture.height) {
                    cancel(gesture);
                    continue;
                }
                gesture.points = points;
                if (action == MotionEvent.ACTION_UP) {
                    for (int n = count; n >= 1; n--) {
                        send(gesture, n == 1 ? MotionEvent.ACTION_UP
                                : MotionEvent.ACTION_POINTER_UP | ((n - 1) << MotionEvent.ACTION_POINTER_INDEX_SHIFT), n);
                    }
                    gesture.downTime = 0;
                } else if (action == MotionEvent.ACTION_CANCEL) {
                    cancel(gesture);
                } else {
                    send(gesture, MotionEvent.ACTION_MOVE, count);
                }
            } else if (gesture.mouse && action == MotionEvent.ACTION_MOVE) {
                gesture.points = points;
                send(gesture, MotionEvent.ACTION_HOVER_MOVE, 1);
            }
        }
    }

    private void send(Gesture gesture, int action, int count) throws Exception {
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        int masked = action & MotionEvent.ACTION_MASK;
        boolean released = masked == MotionEvent.ACTION_UP || masked == MotionEvent.ACTION_CANCEL
                || masked == MotionEvent.ACTION_HOVER_MOVE;
        for (int i = 0; i < count; i++) {
            properties[i] = new MotionEvent.PointerProperties();
            properties[i].id = i;
            properties[i].toolType = gesture.mouse ? MotionEvent.TOOL_TYPE_MOUSE : MotionEvent.TOOL_TYPE_FINGER;
            gesture.points[i].pressure = released ? 0 : 1;
        }
        long now = SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(gesture.downTime == 0 ? now : gesture.downTime, now,
                action, count, properties, gesture.points, 0,
                gesture.mouse && !released ? MotionEvent.BUTTON_PRIMARY : 0,
                1, 1, 0, 0, gesture.mouse ? InputDevice.SOURCE_MOUSE : InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            // ASYNC preserves order without waiting for app handling or drawing.
            if (!((Boolean) inject.invoke(manager, event, 0))) throw new IOException("Input rejected");
        } finally {
            event.recycle();
        }
    }

    private void cancel(Gesture gesture) {
        if (gesture.downTime == 0) return;
        try { send(gesture, MotionEvent.ACTION_CANCEL, gesture.points.length); } catch (Exception ignored) {
            // Disconnect cleanup must attempt both input sources.
        }
        gesture.downTime = 0;
    }

    private static final class Gesture {
        final boolean mouse;
        long downTime;
        int width;
        int height;
        MotionEvent.PointerCoords[] points;

        Gesture(boolean mouse) { this.mouse = mouse; }
    }
}
