package com.openai.snapo.desktop.link

import com.openai.snapo.desktop.protocol.AppIcon
import com.openai.snapo.desktop.protocol.Hello
import com.openai.snapo.desktop.protocol.SnapONetRecord

sealed interface SnapORecord {
    data class HelloRecord(val value: Hello) : SnapORecord
    data class AppIconRecord(val value: AppIcon) : SnapORecord
    data object ReplayComplete : SnapORecord
    data class NetworkEvent(val value: SnapONetRecord) : SnapORecord

    /**
     * Preserve the raw NDJSON line to help debugging schema mismatches.
     *
     * Avoid logging this unconditionally; it can contain request/response bodies.
     */
    data class Unknown(val type: String, val rawJson: String) : SnapORecord
}
