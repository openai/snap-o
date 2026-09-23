package com.openai.snapo.clipboard;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.ContextWrapper;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PersistableBundle;
import android.os.UserHandle;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Session-scoped clipboard access under the ADB shell identity. */
public final class Main {
    private static final int VERSION = 1;
    private static final int MAX_BYTES = 1024 * 1024;
    private final ClipboardManager clipboard;
    private final DataOutputStream output = new DataOutputStream(System.out);
    private String lastText;

    private Main(ClipboardManager clipboard) {
        this.clipboard = clipboard;
    }

    public static void main(String[] args) {
        try {
            if (args.length != 1 && (args.length != 2 || !args[1].equals("keyboard"))) {
                throw new IllegalArgumentException("Expected temporary directory and optional keyboard mode");
            }
            // ART has loaded the DEX. ADB disconnect can kill the launch shell before its EXIT trap.
            File directory = new File(args[0]);
            if (!new File(directory, "helper.jar").delete() || !directory.delete()) {
                throw new IOException("Cannot remove temporary helper");
            }
            ClipboardManager clipboard = createClipboard();
            if (args.length == 2) new Keyboard(clipboard).run();
            else new Main(clipboard).run();
        } catch (Exception error) {
            // Framework errors can contain clipboard contents. Keep diagnostics generic.
            System.err.println("Snap-O clipboard helper stopped.");
            System.exit(1);
        }
    }

    static ClipboardManager createClipboard() throws Exception {
        Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        int user = currentUser();
        UserHandle handle = (UserHandle) UserHandle.class.getMethod("of", int.class).invoke(null, user);
        Context userContext = (Context) Context.class.getMethod("createContextAsUser", UserHandle.class, int.class)
                .invoke(system, handle, 0);
        // Package contexts retain the system operation package. ClipboardService needs our shell identity.
        Context shell = new ContextWrapper(userContext.createPackageContext("com.android.shell", 0)) {
            @Override public String getOpPackageName() {
                // Reconnect for the new user rather than syncing a background user's clipboard.
                if (currentUser() != user) throw new SecurityException("Android user changed");
                return "com.android.shell";
            }
        };
        return ClipboardManager.class.getConstructor(Context.class, Handler.class)
                .newInstance(shell, new Handler(Looper.getMainLooper()));
    }

    private static int currentUser() {
        try {
            return (Integer) Class.forName("android.app.ActivityManager").getMethod("getCurrentUser").invoke(null);
        } catch (Exception error) {
            throw new IllegalStateException("Android user unavailable");
        }
    }

    private void run() throws IOException {
        output.writeInt(VERSION);
        // Register before the initial snapshot so changes cannot fall between them.
        clipboard.addPrimaryClipChangedListener(() -> {
            try {
                sendClipboard(false);
            } catch (Exception error) {
                System.exit(1);
            }
        });
        sendClipboard(true);
        new Thread(() -> {
            try {
                DataInputStream input = new DataInputStream(System.in);
                while (true) {
                    String text = readText(input);
                    if (!text.isEmpty()) {
                        synchronized (this) {
                            ClipData clip = ClipData.newPlainText(null, text);
                            if (Build.VERSION.SDK_INT >= 33) {
                                // System UI honors this flag for shell-based clipboard synchronization.
                                PersistableBundle extras = new PersistableBundle(1);
                                extras.putBoolean("com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY", true);
                                clip.getDescription().setExtras(extras);
                            }
                            clipboard.setPrimaryClip(clip);
                            lastText = text;
                        }
                    }
                }
            } catch (EOFException disconnected) {
                System.exit(0);
            } catch (Exception error) {
                System.exit(1);
            }
        }, "snapo-clipboard-input").start();
        Looper.loop();
    }

    private synchronized void sendClipboard(boolean initial) throws IOException {
        ClipData clip = clipboard.getPrimaryClip();
        CharSequence value = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).getText();
        String text = value == null ? "" : value.toString();
        if (text.length() > MAX_BYTES) text = "";
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_BYTES) bytes = new byte[0];
        if (!initial && (bytes.length == 0 || text.equals(lastText))) return;
        output.writeInt(bytes.length);
        output.write(bytes);
        output.flush();
        lastText = text;
    }

    static String readText(DataInputStream input) throws IOException {
        int length = input.readInt();
        if (length < 0 || length > MAX_BYTES) throw new IOException("Invalid clipboard length");
        byte[] bytes = new byte[length];
        input.readFully(bytes);
        return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString();
    }
}
