package com.openai.snapo.video;

/** Bounds frames across the whole transport, including SSH and kernel buffers. */
final class FrameWindow {
    private final int capacity;
    private int pending;

    FrameWindow(int capacity) {
        if (capacity < 1) throw new IllegalArgumentException("Invalid frame capacity");
        this.capacity = capacity;
    }

    synchronized boolean hasCapacity() {
        return pending < capacity;
    }

    synchronized boolean tryAcquire() {
        if (pending == capacity) return false;
        pending++;
        return true;
    }

    synchronized void acknowledge() {
        if (pending > 0) pending--;
    }
}
