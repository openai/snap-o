package com.openai.snapo.network

import com.openai.snapo.network.record.Header
import com.openai.snapo.network.record.RequestFailed
import com.openai.snapo.network.record.RequestWillBeSent
import com.openai.snapo.network.record.ResponseReceived
import com.openai.snapo.network.record.ResponseStreamClosed
import com.openai.snapo.network.record.ResponseStreamEvent
import com.openai.snapo.network.record.SnapONetRecord
import com.openai.snapo.network.record.TimedRecord
import com.openai.snapo.network.record.WebSocketCancelled
import com.openai.snapo.network.record.WebSocketClosed
import com.openai.snapo.network.record.WebSocketFailed
import com.openai.snapo.network.record.WebSocketMessageReceived
import com.openai.snapo.network.record.WebSocketMessageSent
import com.openai.snapo.network.record.WebSocketOpened
import com.openai.snapo.network.record.WebSocketWillOpen
import com.openai.snapo.network.record.perWebSocketRecord
import java.util.ArrayList

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
                is ResponseReceived -> candidate.id == head.id && !activeResponseStreams.contains(
                    head.id
                )

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

    private fun evictWebSocketConversation(head: SnapONetRecord): Boolean {
        val wsHead = head.perWebSocketRecord() ?: return false
        if (openWebSockets.contains(wsHead.id)) {
            return false
        }
        val iterator = records.iterator()
        var removedAny = false
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            val perSocket = candidate.perWebSocketRecord()
            val shouldRemove = perSocket != null && perSocket.id == wsHead.id && candidate !== head
            if (shouldRemove) {
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
        val iterator = records.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (record is TimedRecord && record.tWallMs < cutoff) {
                iterator.remove()
                subtractApproxBytes(record)
                updateWebSocketStateOnRemove(record)
                updateStreamStateOnRemove(record)
            } else {
                break
            }
        }
    }

    private fun removeRecord(iterator: MutableIterator<SnapONetRecord>, record: SnapONetRecord) {
        iterator.remove()
        subtractApproxBytes(record)
        updateWebSocketStateOnRemove(record)
        updateStreamStateOnRemove(record)
    }

    private fun estimateSize(record: SnapONetRecord): Long {
        val base = 64 // rough per-record object overhead
        val payloadEstimate = when (record) {
            is RequestWillBeSent ->
                record.method.length +
                    record.url.length +
                    sizeOfHeaders(record.headers) +
                    record.body.length

            is ResponseReceived ->
                sizeOfHeaders(record.headers) +
                    record.bodyPreview.length +
                    record.body.length

            is ResponseStreamEvent -> record.raw.length
            is ResponseStreamClosed -> record.reason.length + record.message.length
            is WebSocketWillOpen -> record.url.length + sizeOfHeaders(record.headers)
            is WebSocketOpened -> sizeOfHeaders(record.headers)
            is WebSocketMessageSent -> record.preview.length
            is WebSocketMessageReceived -> record.preview.length

            else -> 0
        }
        return (base + payloadEstimate).toLong()
    }

    private fun subtractApproxBytes(record: SnapONetRecord) {
        approxBytes -= estimateSize(record)
        if (approxBytes < 0) approxBytes = 0
    }

    private fun sizeOfHeaders(headers: List<Header>): Int =
        headers.sumOf { it.name.length + it.value.length }
}

private val String?.length: Int get() = this?.length ?: 0
