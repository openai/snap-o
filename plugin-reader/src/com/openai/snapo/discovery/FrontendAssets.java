package com.openai.snapo.discovery;

import android.content.res.AssetManager;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/** Reads the frontend ZIP named by an installed tool descriptor. */
final class FrontendAssets {
    private static final int MAX_BYTES = 16 * 1024 * 1024;

    private FrontendAssets() {}

    static byte[] read(AssetManager assets, String path) throws Exception {
        if (!validPath(path)) throw new IllegalArgumentException("Invalid frontend asset path.");
        try (InputStream input = assets.open(path)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[16384];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() + count > MAX_BYTES) {
                    throw new IllegalArgumentException("Frontend archive is too large.");
                }
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        }
    }

    static boolean validPath(String path) {
        if (path.isEmpty() || path.length() > 1024 || path.indexOf('\\') >= 0 || !path.endsWith(".zip")) return false;
        for (int index = 0; index < path.length(); index++) {
            char c = path.charAt(index);
            if (c < 32 || c == 127) return false;
        }
        for (String part : path.split("/", -1)) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) return false;
        }
        return true;
    }
}
