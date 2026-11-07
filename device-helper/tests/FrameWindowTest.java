package com.openai.snapo.video;

public final class FrameWindowTest {
    public static void main(String[] args) throws Exception {
        FrameWindow window = new FrameWindow(2);
        window.acknowledge();
        check(window.tryAcquire());
        check(window.tryAcquire());
        check(!window.hasCapacity());
        check(!window.tryAcquire());

        // The control reader returns one credit while capture is paused.
        Thread reader = new Thread(window::acknowledge);
        reader.start();
        reader.join();
        check(window.hasCapacity());
        check(window.tryAcquire());
        check(!window.tryAcquire());

        window.acknowledge();
        window.acknowledge();
        window.acknowledge();
        check(window.tryAcquire());
        check(window.tryAcquire());
        check(!window.tryAcquire());
        System.out.println("RGBA frame window tests passed");
    }

    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Incorrect frame credit count");
    }
}
