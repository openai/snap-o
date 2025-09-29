package com.openai.snapo.link.core

import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

data class SnapONetConfig(
    /** Keep only the last this-many milliseconds of events in memory. */
    val bufferWindow: Duration = 5.minutes,

    /** Hard caps to avoid runaway memory. */
    val maxBufferedEvents: Int = 10_000,
    val maxBufferedBytes: Long = 16L * 1024 * 1024, // rough estimate based on encoded length

    /** Single-client policy keeps ordering simple. */
    val singleClientOnly: Boolean = true,

    /** For the Hello record; reflect your current redaction mode/prefs. */
    val modeLabel: String = "safe", // or "unredacted"

    /** Whether the server is allowed to start in a non-debug build. */
    val allowRelease: Boolean = false,
)
