package com.openai.snapo.clipboard;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class HeldKeysTest {
    private final List<String> events = new ArrayList<>();
    private final List<HeldKeys.LongPress> timers = new ArrayList<>();
    private final HeldKeys keys = new HeldKeys((time, pressed, code, repeat) ->
            events.add(time + ":" + pressed + ":" + code + ":" + repeat), timers::add);

    public static void main(String[] args) throws Exception {
        new HeldKeysTest().shortPressCancelsRepeat();
        new HeldKeysTest().disconnectReleasesAllKeys();
        new HeldKeysTest().longPressKeepsDownTime();
        new HeldKeysTest().oldTimeoutCannotRepeatNewPress();
        new HeldKeysTest().failedInjectionDoesNotSkipCleanup();
        System.out.println("HeldKeysTest passed");
    }

    private void shortPressCancelsRepeat() throws Exception {
        keys.press(3, 100);
        keys.press(3, 200);
        keys.release(3);
        keys.release(3);
        expect(events.equals(Arrays.asList("100:true:3:0", "100:false:3:0")), "one pair with original down time");

        timers.get(0).send();
        expect(events.size() == 2, "short press cancels the delayed long press");
        expect(timers.size() == 1, "duplicate down schedules no extra timeout");
    }

    private void disconnectReleasesAllKeys() throws Exception {
        keys.press(3, 300);
        keys.press(24, 400);
        keys.releaseAll();
        expect(events.equals(Arrays.asList("300:true:3:0", "400:true:24:0", "300:false:3:0", "400:false:24:0")),
                "disconnect releases every key");
        expect(!keys.contains(3) && !keys.contains(24), "cleanup clears held state");

        for (HeldKeys.LongPress timer : timers) timer.send();
        expect(events.size() == 4, "disconnect cancels all delayed long presses");
    }

    private void longPressKeepsDownTime() throws Exception {
        keys.press(3, 450);
        timers.get(0).send();
        keys.release(3);
        expect(events.equals(Arrays.asList("450:true:3:0", "450:true:3:1", "450:false:3:0")),
                "long press sends one repeat with the original down time before release");
    }

    private void oldTimeoutCannotRepeatNewPress() throws Exception {
        keys.press(3, 460);
        keys.release(3);
        keys.press(3, 460);
        timers.get(0).send();
        expect(events.size() == 3, "an old timeout cannot repeat a new press with the same timestamp");
        timers.get(1).send();
        expect(events.get(3).equals("460:true:3:1"), "the current press still produces its repeat");
        keys.releaseAll();
    }

    private void failedInjectionDoesNotSkipCleanup() throws Exception {
        HeldKeys failing = new HeldKeys((time, pressed, code, repeat) -> {
            events.add(time + ":" + pressed + ":" + code + ":" + repeat);
            if (code == 3) throw new Exception("injection failed");
        }, timers::add);
        try { failing.press(3, 500); } catch (Exception expected) { }
        failing.press(24, 600);
        try { failing.releaseAll(); } catch (Exception expected) { }
        expect(events.contains("500:false:3:0"), "failed injection still gets a release attempt");
        expect(events.contains("600:false:24:0") && !failing.contains(24), "one failure cannot skip another release");
    }

    private static void expect(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
    }
}
