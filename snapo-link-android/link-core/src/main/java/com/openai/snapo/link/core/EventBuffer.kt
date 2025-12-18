package com.openai.snapo.link.core

import kotlinx.serialization.encodeToString
import java.util.ArrayList
import java.util.Collections
import java.util.IdentityHashMap

internal class EventBuffer(
    private val config: NetworkInspectorConfig,
) {

    private val records: MutableList<SnapONetRecord> = ArrayList()
    private var approxBytes: Long = 0L
    private val openWebSockets: MutableSet<String> = mutableSetOf()
    private val activeResponseStreams: MutableSet<String> = mutableSetOf()

    fun append(record: SnapONetRecord) {
        insertSorted(record)
        approxBytes += estimateSize(record)
        updateWebSocketStateOnAdd(record)
        updateStreamStateOnAdd(record)
        evictExpiredIfNeeded(record)
        trimToByteLimit()
        trimToCountLimit()
    }

    fun snapshot(): List<SnapONetRecord> = ArrayList(records)

    private fun insertSorted(record: SnapONetRecord) {
        val insertIndex = findInsertIndex(record)
        records.add(insertIndex, record)
    }

    private fun findInsertIndex(record: SnapONetRecord): Int {
        var low = 0
        var high = records.size
        while (low < high) {
            val mid = (low + high) / 2
            val cmp = compareEventTimes(records[mid], record)
            if (cmp <= 0) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private fun compareEventTimes(a: SnapONetRecord, b: SnapONetRecord): Int {
        val left = eventTime(a)
        val right = eventTime(b)
        return left.compareTo(right)
    }

    private fun eventTime(record: SnapONetRecord): Long {
        return (record as? TimedRecord)?.tWallMs ?: Long.MAX_VALUE
    }

    private fun evictExpiredIfNeeded(record: SnapONetRecord) {
        if (record is TimedRecord) {
            val cutoff = record.tWallMs - config.bufferWindow.inWholeMilliseconds
            evictExpiredRecords(cutoff)
        }
    }

    private fun trimToByteLimit() {
        while (approxBytes > config.maxBufferedBytes && records.isNotEmpty()) {
            if (!evictFirstEligible()) {
                break
            }
        }
    }

    private fun trimToCountLimit() {
        while (records.size > config.maxBufferedEvents && records.isNotEmpty()) {
            if (!evictFirstEligible()) {
                break
            }
        }
    }

    private fun evictFirstEligible(): Boolean {
        val iterator = records.iterator()
        var evicted = false
        while (iterator.hasNext() && !evicted) {
            val record = iterator.next()
            val shouldRemove = when (record) {
                is RequestWillBeSent -> evictRequestTerminal(record)
                is WebSocketWillOpen -> evictWebSocketConversation(record)
                is WebSocketOpened -> evictWebSocketConversation(record)
                else -> true
            }
            if (shouldRemove) {
                removeRecord(iterator, record)
                evicted = true
            }
        }
        return evicted
    }

    private fun updateWebSocketStateOnAdd(record: SnapONetRecord) {
        when (record) {
            is WebSocketWillOpen -> openWebSockets.add(record.id)
            is WebSocketOpened -> openWebSockets.add(record.id)
            is WebSocketClosed -> openWebSockets.remove(record.id)
            is WebSocketFailed -> openWebSockets.remove(record.id)
            is WebSocketCancelled -> openWebSockets.remove(record.id)
            else -> Unit
        }
    }

    private fun updateWebSocketStateOnRemove(record: SnapONetRecord) {
        when (record) {
            is WebSocketWillOpen -> openWebSockets.remove(record.id)
            is WebSocketOpened -> openWebSockets.remove(record.id)
            else -> Unit
        }
    }

    private fun updateStreamStateOnAdd(record: SnapONetRecord) {
        when (record) {
            is ResponseStreamEvent -> activeResponseStreams.add(record.id)
            is ResponseStreamClosed -> activeResponseStreams.remove(record.id)
            is RequestFailed -> activeResponseStreams.remove(record.id)
            else -> Unit
        }
    }

    private fun updateStreamStateOnRemove(record: SnapONetRecord) {
        when (record) {
            is ResponseStreamClosed -> activeResponseStreams.remove(record.id)
            is RequestFailed -> activeResponseStreams.remove(record.id)
            else -> Unit
        }
    }

    private fun evictRequestTerminal(head: RequestWillBeSent): Boolean {
        return records.indexOfFirst { candidate ->
            candidate !== head && when (candidate) {
                is ResponseReceived -> candidate.id == head.id && !activeResponseStreams.contains(head.id)
                is RequestFailed -> candidate.id == head.id
                is ResponseStreamClosed -> candidate.id == head.id
                else -> false
            }
        }
            .takeIf { it >= 0 }
            ?.let { index ->
                val candidate = records.removeAt(index)
                subtractApproxBytes(candidate)
                updateWebSocketStateOnRemove(candidate)
                updateStreamStateOnRemove(candidate)
                removeAdditionalRequestRecords(head.id)
                true
            }
            ?: false
    }

    private fun evictWebSocketConversation(head: PerWebSocketRecord): Boolean {
        if (openWebSockets.contains(head.id)) {
            return false
        }
        val iterator = records.iterator()
        var removedAny = false
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate === head) continue
            if (candidate is PerWebSocketRecord && candidate.id == head.id) {
                iterator.remove()
                subtractApproxBytes(candidate)
                updateWebSocketStateOnRemove(candidate)
                updateStreamStateOnRemove(candidate)
                removedAny = true
            }
        }
        return removedAny
    }

    private fun removeAdditionalRequestRecords(requestId: String) {
        val iterator = records.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            when (record) {
                is ResponseReceived -> if (record.id == requestId) {
                    iterator.remove()
                    subtractApproxBytes(record)
                    updateStreamStateOnRemove(record)
                }

                is ResponseStreamEvent -> if (record.id == requestId) {
                    iterator.remove()
                    subtractApproxBytes(record)
                    updateStreamStateOnRemove(record)
                }

                else -> Unit
            }
        }
    }

    private fun evictExpiredRecords(cutoff: Long) {
        val state = buildExpiredRecordPruneState(cutoff)
        markRequestRemovals(state)
        markWebSocketRemovals(state)
        removeMarkedRecords(state.toRemove)
    }

    private fun buildExpiredRecordPruneState(cutoff: Long): ExpiredRecordPruneState {
        val state = ExpiredRecordPruneState()
        for (record in records) {
            val time = eventTime(record)
            when {
                record is PerRequestRecord -> collectRequestExpiryState(record, time, cutoff, state)
                record is PerWebSocketRecord -> collectWebSocketExpiryState(record, time, cutoff, state)
                time < cutoff -> state.toRemove.add(record)
            }
        }
        return state
    }

    private fun collectRequestExpiryState(
        record: PerRequestRecord,
        time: Long,
        cutoff: Long,
        state: ExpiredRecordPruneState,
    ) {
        val requestState = state.requestStates.getOrPut(record.id) { RequestPruneState() }
        if (time >= cutoff) {
            requestState.hasRecentRecords = true
            return
        }

        when (record) {
            is RequestWillBeSent -> requestState.start = record
            is ResponseStreamEvent -> requestState.oldEvents.add(record)
            is ResponseReceived -> {
                if (!activeResponseStreams.contains(record.id)) {
                    requestState.terminal = record
                }
                requestState.oldRecords.add(record)
            }

            is RequestFailed -> {
                requestState.terminal = record
                requestState.oldRecords.add(record)
            }

            is ResponseStreamClosed -> {
                requestState.terminal = record
                requestState.oldRecords.add(record)
            }
        }
    }

    private fun collectWebSocketExpiryState(
        record: PerWebSocketRecord,
        time: Long,
        cutoff: Long,
        state: ExpiredRecordPruneState,
    ) {
        val webSocketState = state.webSocketStates.getOrPut(record.id) { WebSocketPruneState() }
        if (time >= cutoff) {
            webSocketState.hasRecentRecords = true
            return
        }

        when (record) {
            is WebSocketWillOpen,
            is WebSocketOpened -> webSocketState.startRecords.add(record)

            is WebSocketClosed,
            is WebSocketFailed,
            is WebSocketCancelled -> {
                webSocketState.terminal = record
                webSocketState.oldRecords.add(record)
            }

            else -> webSocketState.oldRecords.add(record)
        }
    }

    private fun markRequestRemovals(state: ExpiredRecordPruneState) {
        for ((id, requestState) in state.requestStates) {
            if (requestState.oldEvents.isNotEmpty()) {
                requestState.oldEvents.forEach(state.toRemove::add)
            }
            val hasRecent = requestState.hasRecentRecords || activeResponseStreams.contains(id)
            if (!hasRecent && requestState.terminal != null) {
                requestState.start?.let(state.toRemove::add)
                requestState.oldRecords.forEach(state.toRemove::add)
            }
        }
    }

    private fun markWebSocketRemovals(state: ExpiredRecordPruneState) {
        for ((id, webSocketState) in state.webSocketStates) {
            val isOpen = openWebSockets.contains(id)
            if (webSocketState.hasRecentRecords || isOpen) {
                webSocketState.oldRecords.forEach(state.toRemove::add)
            } else if (webSocketState.terminal != null) {
                webSocketState.startRecords.forEach(state.toRemove::add)
                webSocketState.oldRecords.forEach(state.toRemove::add)
            }
        }
    }

    private fun removeMarkedRecords(recordsToRemove: MutableSet<SnapONetRecord>) {
        if (recordsToRemove.isEmpty()) return
        val iterator = records.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (!recordsToRemove.contains(record)) continue
            removeRecord(iterator, record)
        }
    }

    private fun removeRecord(
        iterator: MutableIterator<SnapONetRecord>,
        record: SnapONetRecord,
    ) {
        iterator.remove()
        subtractApproxBytes(record)
        updateWebSocketStateOnRemove(record)
        updateStreamStateOnRemove(record)
    }

    private fun subtractApproxBytes(record: SnapONetRecord) {
        approxBytes = (approxBytes - estimateSize(record)).coerceAtLeast(0)
    }

    private fun estimateSize(record: SnapONetRecord): Int {
        return Ndjson.encodeToString(SnapONetRecord.serializer(), record).length
    }

    private data class RequestPruneState(
        var start: RequestWillBeSent? = null,
        var terminal: SnapONetRecord? = null,
        val oldEvents: MutableList<ResponseStreamEvent> = mutableListOf(),
        val oldRecords: MutableList<SnapONetRecord> = mutableListOf(),
        var hasRecentRecords: Boolean = false,
    )

    private data class WebSocketPruneState(
        val startRecords: MutableList<PerWebSocketRecord> = mutableListOf(),
        var terminal: PerWebSocketRecord? = null,
        val oldRecords: MutableList<PerWebSocketRecord> = mutableListOf(),
        var hasRecentRecords: Boolean = false,
    )

    private data class ExpiredRecordPruneState(
        val requestStates: MutableMap<String, RequestPruneState> = mutableMapOf(),
        val webSocketStates: MutableMap<String, WebSocketPruneState> = mutableMapOf(),
        val toRemove: MutableSet<SnapONetRecord> = Collections.newSetFromMap(IdentityHashMap()),
    )
}
