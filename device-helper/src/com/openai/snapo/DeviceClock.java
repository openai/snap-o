package com.openai.snapo;

import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Reports time on the same monotonic clock as the screen and audio capture streams. */
final class DeviceClock {
    private static final int MAGIC = 0x534e5431; // SNT1

    static void serve(InputStream input, DataOutputStream output) throws IOException {
        output.writeInt(MAGIC);
        output.flush();
        while (input.read() == 1) {
            output.writeLong(System.nanoTime() / 1000);
            output.flush();
        }
    }
}
