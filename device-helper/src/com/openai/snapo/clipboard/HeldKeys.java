package com.openai.snapo.clipboard;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/** Keeps the original down time and releases keys when their input connection ends. */
final class HeldKeys {
    interface Sink {
        void send(long downTime, boolean pressed, int code, int repeatCount) throws Exception;
    }

    interface LongPress {
        void send() throws Exception;
    }

    interface Scheduler {
        void schedule(LongPress action);
    }

    private static final class Press {
        final long downTime;
        boolean released;

        Press(long downTime) {
            this.downTime = downTime;
        }
    }

    private final Sink sink;
    private final Scheduler scheduler;
    private final Map<Integer, Press> presses = new LinkedHashMap<>();

    HeldKeys(Sink sink, Scheduler scheduler) {
        this.sink = sink;
        this.scheduler = scheduler;
    }

    synchronized boolean contains(int code) {
        return presses.containsKey(code);
    }

    synchronized void press(int code, long now) throws Exception {
        if (contains(code)) return;
        Press press = new Press(now);
        // A failed injection may still have reached Android. Keep it for cleanup.
        presses.put(code, press);
        sink.send(now, true, code, 0);
        scheduler.schedule(() -> {
            synchronized (this) {
                // A release or a new press invalidates this timeout, even in the same millisecond.
                if (presses.get(code) == press && !press.released) sink.send(now, true, code, 1);
            }
        });
    }

    synchronized void release(int code) throws Exception {
        Press press = presses.get(code);
        if (press == null) return;
        press.released = true;
        sink.send(press.downTime, false, code, 0);
        presses.remove(code);
    }

    synchronized void releaseAll() throws Exception {
        Exception failure = null;
        for (int code : new ArrayList<>(presses.keySet())) {
            try {
                release(code);
            } catch (Exception error) {
                failure = error;
            }
        }
        if (failure != null) throw failure;
    }
}
