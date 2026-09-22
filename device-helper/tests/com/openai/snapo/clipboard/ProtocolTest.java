package com.openai.snapo.clipboard;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public final class ProtocolTest {
    public static void main(String[] args) throws Exception {
        String text = "Hello 🌍\n日本語\u0000\"quoted\"";
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (!text.equals(Main.readText(frame(bytes.length, bytes)))) throw new AssertionError("Unicode");
        if (!Main.readText(frame(0, new byte[0])).isEmpty()) throw new AssertionError("Empty");
        byte[] maximum = new byte[1024 * 1024];
        java.util.Arrays.fill(maximum, (byte) 'a');
        if (Main.readText(frame(maximum.length, maximum)).length() != maximum.length) throw new AssertionError("Limit");
        rejects(frame(-1, new byte[0]));
        rejects(frame(maximum.length + 1, new byte[0]));
        rejects(frame(10, new byte[]{1}));
        rejects(frame(2, new byte[]{(byte) 0xc3, 0x28}));
        System.out.println("Clipboard protocol tests passed (Unicode, limits, malformed frames).");
    }

    private static DataInputStream frame(int length, byte[] bytes) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        DataOutputStream output = new DataOutputStream(buffer);
        output.writeInt(length);
        output.write(bytes);
        return new DataInputStream(new ByteArrayInputStream(buffer.toByteArray()));
    }

    private static void rejects(DataInputStream input) throws Exception {
        try {
            Main.readText(input);
            throw new AssertionError("Accepted invalid frame");
        } catch (IOException expected) { }
    }
}
