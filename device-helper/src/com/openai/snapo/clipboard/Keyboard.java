package com.openai.snapo.clipboard;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Build;
import android.os.Looper;
import android.os.PersistableBundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/** Ordered input for one focused preview. No text is passed through a shell command. */
final class Keyboard {
    private static final int VERSION = 1;
    private final ClipboardManager clipboard;
    private final Object inputManager;
    private final Method inject;
    private final Object clipboardLock = new Object();
    private long clipboardRevision;

    Keyboard(ClipboardManager clipboard) throws Exception {
        this.clipboard = clipboard;
        Class<?> type;
        try {
            type = Class.forName("android.hardware.input.InputManagerGlobal");
        } catch (ClassNotFoundException olderAndroid) {
            type = Class.forName("android.hardware.input.InputManager");
        }
        inputManager = type.getMethod("getInstance").invoke(null);
        inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
        clipboard.addPrimaryClipChangedListener(() -> {
            synchronized (clipboardLock) {
                clipboardRevision++;
                clipboardLock.notifyAll();
            }
        });
    }

    void run() throws IOException {
        DataOutputStream output = new DataOutputStream(System.out);
        output.writeInt(VERSION);
        output.flush();
        new Thread(() -> {
            try {
                DataInputStream input = new DataInputStream(System.in);
                while (true) {
                    int command = input.readInt();
                    if (command == 1) {
                        String text = Main.readText(input);
                        KeyEvent[] events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
                                .getEvents(text.toCharArray());
                        if (events == null) {
                            output.writeInt(2);
                            output.flush();
                            continue;
                        }
                        for (KeyEvent event : events) send(event);
                    } else if (command == 2) {
                        int code = input.readInt();
                        int modifiers = input.readInt();
                        if (code <= KeyEvent.KEYCODE_UNKNOWN || code > KeyEvent.getMaxKeyCode()
                                || (modifiers & ~KeyEvent.META_SHIFT_ON) != 0) {
                            throw new IOException("Invalid key");
                        }
                        key(code, modifiers);
                    } else if (command == 3) {
                        String text = Main.readText(input);
                        if (!text.isEmpty()) {
                            ClipData clip = ClipData.newPlainText(null, text);
                            if (Build.VERSION.SDK_INT >= 33) {
                                PersistableBundle extras = new PersistableBundle(1);
                                extras.putBoolean("com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY", true);
                                clip.getDescription().setExtras(extras);
                            }
                            clipboard.setPrimaryClip(clip);
                            key(KeyEvent.KEYCODE_PASTE, 0);
                        }
                    } else if (command == 4) {
                        String text = copy();
                        if (text != null) {
                            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
                            if (bytes.length > 1024 * 1024) throw new IOException("Copy is too large");
                            output.writeInt(1);
                            output.writeInt(bytes.length);
                            output.write(bytes);
                            output.flush();
                            continue;
                        }
                    } else {
                        throw new IOException("Invalid input command");
                    }
                    output.writeInt(0);
                    output.flush();
                }
            } catch (EOFException disconnected) {
                System.exit(0);
            } catch (Exception error) {
                // Framework exceptions may contain typed text.
                System.exit(1);
            }
        }, "snapo-keyboard-input").start();
        Looper.loop();
    }

    private String copy() throws Exception {
        long before;
        synchronized (clipboardLock) { before = clipboardRevision; }
        key(KeyEvent.KEYCODE_COPY, 0);
        synchronized (clipboardLock) {
            long deadline = SystemClock.uptimeMillis() + 500;
            while (clipboardRevision == before) {
                long remaining = deadline - SystemClock.uptimeMillis();
                if (remaining <= 0) return null;
                clipboardLock.wait(remaining);
            }
        }
        ClipData clip = clipboard.getPrimaryClip();
        CharSequence text = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).getText();
        return text == null ? null : text.toString();
    }

    private void key(int code, int modifiers) throws Exception {
        long now = SystemClock.uptimeMillis();
        boolean shift = (modifiers & KeyEvent.META_SHIFT_ON) != 0;
        int meta = shift ? KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON : 0;
        // Input methods may track modifier presses separately from an event's meta state.
        if (shift) keyEvent(now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_SHIFT_LEFT, meta);
        try {
            keyEvent(now, KeyEvent.ACTION_DOWN, code, meta);
            keyEvent(now, KeyEvent.ACTION_UP, code, meta);
        } finally {
            if (shift) keyEvent(now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_SHIFT_LEFT, 0);
        }
    }

    private void keyEvent(long downTime, int action, int code, int meta) throws Exception {
        send(new KeyEvent(downTime, SystemClock.uptimeMillis(), action, code, 0, meta,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD));
    }

    private void send(KeyEvent event) throws Exception {
        // WAIT_FOR_FINISH keeps a subsequent paste or copy behind the preceding input.
        if (!(Boolean) inject.invoke(inputManager, event, 2)) throw new IOException("Input rejected");
    }
}
