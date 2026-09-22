package com.openai.snapo.clipboard;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Build;
import java.io.BufferedReader;
import java.io.InputStreamReader;

/** Runs only in device tests; never bundled with the app. */
public final class DeviceFixture {
    static final String HOST_TEXT = "Snap-O host 🌍\n日本語\u0000";
    static final String DEVICE_TEXT = "Snap-O device 🧪\nمرحبا";

    public static void main(String[] args) {
        int status = 0;
        try {
            ClipboardManager clipboard = Main.createClipboard();
            ClipData original = clipboard.getPrimaryClip();
            try {
                System.out.println("ready");
                BufferedReader input = new BufferedReader(new InputStreamReader(System.in));
                String command;
                while ((command = input.readLine()) != null) {
                    if (command.equals("restore")) {
                        break;
                    } else if (command.equals("verify-host")) {
                        long deadline = System.nanoTime() + 3_000_000_000L;
                        while (true) {
                            ClipData current = clipboard.getPrimaryClip();
                            if (current != null && HOST_TEXT.contentEquals(current.getItemAt(0).getText())) {
                                if (Build.VERSION.SDK_INT >= 33 && (current.getDescription().getExtras() == null ||
                                        !current.getDescription().getExtras().getBoolean("com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY"))) {
                                    throw new AssertionError("Clipboard overlay was not suppressed");
                                }
                                break;
                            }
                            if (System.nanoTime() >= deadline) throw new AssertionError("Host text differs");
                            Thread.sleep(10);
                        }
                    } else if (command.equals("copy-device")) {
                        clipboard.setPrimaryClip(ClipData.newPlainText(null, DEVICE_TEXT));
                    } else {
                        throw new IllegalArgumentException("Unknown test command");
                    }
                    System.out.println("ok");
                }
            } finally {
                if (original != null) clipboard.setPrimaryClip(original);
                else clipboard.clearPrimaryClip();
                System.out.println("restored");
            }
        } catch (Throwable error) {
            System.err.println("Clipboard device fixture failed.");
            status = 1;
        }
        System.exit(status);
    }
}
