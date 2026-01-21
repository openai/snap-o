package com.openai.snapo.link.core

data class SnapOLinkConfig(
    /** For the Hello record; reflect your current redaction mode/prefs. */
    val modeLabel: String = "safe", // or "unredacted"

    /** Whether the server is allowed to start in a non-debug build. */
    val allowRelease: Boolean = false,
)
