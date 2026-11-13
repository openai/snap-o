package com.openai.snapo;

import java.io.DataOutputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Arrays;

/** Identifies the loaded build before any mode accesses the device. */
public final class Helper {
    public static void main(String[] args) throws IOException {
        DataOutputStream output = new DataOutputStream(new FileOutputStream(FileDescriptor.out));
        output.writeBytes("SNHB" + Build.ID);
        output.flush();
        if (args.length < 2 || !Build.ID.equals(args[0])) return;
        String[] options = Arrays.copyOfRange(args, 2, args.length);
        switch (args[1]) {
            case "video": com.openai.snapo.video.Main.main(options); break;
            case "pointer": com.openai.snapo.pointer.Main.main(options); break;
            case "clipboard": com.openai.snapo.clipboard.Main.main(options); break;
            default: throw new IllegalArgumentException("Unknown helper mode");
        }
    }
}
