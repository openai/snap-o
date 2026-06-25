package com.openai.snapo.network

import java.util.ArrayList
import java.util.IdentityHashMap

internal data class CapturedBody(
    val body: String,
    val encoding: String?,
)

internal data class SequencedNetworkEvent(
    val snapoSequence: Long,
    val record: NetworkEventRecord,
)

internal data class EventBufferSnapshot(
    val records: List<SequencedNetworkEvent>,
    val watermark: Long,
)

internal class EventBuffer(
    private val config: NetworkInspectorConfig,
) {

    private val records: MutableList<NetworkEventRecord> = ArrayList()
    private val sequenceByRecord = IdentityHashMap<NetworkEventRecord, Long>()
    private var latestSequence: Long = 0L
    private var approxBytes: Long = 0L
    private val requestBodiesById: MutableMap<String, CapturedBody> = mutableMapOf()
    private val responseBodiesById: MutableMap<String, CapturedBody> = mutableMapOf()
    private val openWebSockets: MutableSet<String> = mutableSetOf()
    private val activeResponseStreams: MutableSet<String> = mutableSetOf()

    fun append(record: NetworkEventRecord): Long {
        val normalizedRecord = normalizeRecord(record)
        val sequence = ++latestSequence
        sequenceByRecord[normalizedRecord] = sequence
        insertSorted(normalizedRecord)
        approxBytes += estimateSize(normalizedRecord)
        updateWebSocketStateOnAdd(normalizedRecord)
        updateStreamStateOnAdd(normalizedRecord)
        evictExpiredIfNeeded(normalizedRecord)
        trimToByteLimit()
        trimToCountLimit()
        return sequence
    }

    fun snapshot(): List<NetworkEventRecord> = ArrayList(records)

    fun sequencedSnapshot(): EventBufferSnapshot = EventBufferSnapshot(
        records = records.map { record ->
            SequencedNetworkEvent(
                snapoSequence = checkNotNull(sequenceByRecord[record]),
                record = record,
            )
        },
        watermark = latestSequence,
    )

    fun findRequestBody(requestId: String): CapturedBody? = requestBodiesById[requestId]

    fun findResponseBody(requestId: String): CapturedBody? = responseBodiesById[requestId]

    fun updateLatestResponseBody(
        requestId: String,
        bodyPreview: String?,
        body: String?,
        bodyEncoding: String?,
        bodyTruncatedBytes: Long?,
        bodySize: Long?,
    ): Boolean {
        val hasRelatedRecords = records.any { candidate ->
            (candidate as? PerRequestRecord)?.id == requestId
        }
        if (!body.isNullOrEmpty() && hasRelatedRecords) {
            upsertResponseBody(requestId, body, bodyEncoding)
        }
        val index = records.indexOfLast { candidate ->
            (candidate as? ResponseReceived)?.id == requestId
        }
        if (index < 0) {
            trimToByteLimit()
            return !body.isNullOrEmpty() && hasRelatedRecords
        }
        val existing = records[index] as? ResponseReceived ?: return false
        val updated = existing.copy(
            bodyPreview = bodyPreview,
            body = null,
            bodyEncoding = bodyEncoding,
            bodyTruncatedBytes = bodyTruncatedBytes,
            bodySize = bodySize ?: existing.bodySize,
        )
        val sequence = checkNotNull(sequenceByRecord.remove(existing))
        records[index] = updated
        sequenceByRecord[updated] = sequence
        subtractApproxBytes(existing)
        approxBytes += estimateSize(updated)
        trimToByteLimit()
        return true
    }

    private fun normalizeRecord(record: NetworkEventRecord): NetworkEventRecord {
        return when (record) {
            is RequestWillBeSent -> {
                if (!record.body.isNullOrEmpty()) {
                    upsertRequestBody(record.id, record.body, record.bodyEncoding)
                }
                if (record.body == null) record else record.copy(body = null)
            }

            is ResponseReceived -> {
                if (!record.body.isNullOrEmpty()) {
                    upsertResponseBody(record.id, record.body, record.bodyEncoding)
                }
                if (record.body == null) record else record.copy(body = null)
            }

            else -> record
        }
    }

    private fun insertSorted(record: NetworkEventRecord) {
        val insertIndex = findInsertIndex(record)
        records.add(insertIndex, record)
    }

    private fun findInsertIndex(record: NetworkEventRecord): Int {
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

    private fun compareEventTimes(a: NetworkEventRecord, b: NetworkEventRecord): Int {
        val left = eventTime(a)
        val right = eventTime(b)
        return left.compareTo(right)
    }

    private fun eventTime(record: NetworkEventRecord): Long {
        return (record as? TimedRecord)?.tWallMs ?: Long.MAX_VALUE
    }

    private fun evictExpiredIfNeeded(record: NetworkEventRecord) {
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
        val record = oldestCompletedConversation() ?: records.firstOrNull() ?: return false
        return removeConversation(record)
    }

    private fun oldestCompletedConversation(): NetworkEventRecord? {
        val completedRequestIds = completedRequestIds()
        return records.firstOrNull { record ->
            when (record) {
                is PerRequestRecord -> completedRequestIds.contains(record.id)
                is PerWebSocketRecord -> !openWebSockets.contains(record.id)
            }
        }
    }

    private fun removeConversation(record: NetworkEventRecord): Boolean {
        return when (record) {
            is PerRequestRecord -> removeRequestConversation(record.id)
            is PerWebSocketRecord -> removeWebSocketConversation(record.id)
        }
    }

    private fun updateWebSocketStateOnAdd(record: NetworkEventRecord) {
        when (record) {
            is WebSocketWillOpen -> openWebSockets.add(record.id)
            is WebSocketOpened -> openWebSockets.add(record.id)
            is WebSocketClosed -> openWebSockets.remove(record.id)
            is WebSocketFailed -> openWebSockets.remove(record.id)
            is WebSocketCancelled -> openWebSockets.remove(record.id)
            else -> Unit
        }
    }

    private fun updateStreamStateOnAdd(record: NetworkEventRecord) {
        when (record) {
            is ResponseStreamEvent -> activeResponseStreams.add(record.id)
            is ResponseStreamClosed -> activeResponseStreams.remove(record.id)
            is ResponseFinished -> activeResponseStreams.remove(record.id)
            is RequestFailed -> activeResponseStreams.remove(record.id)
            else -> Unit
        }
    }

    private fun updateConversationStateOnRemove(record: NetworkEventRecord) {
        when (record) {
            is PerRequestRecord -> {
                val hasRemainingRecords = records.any { candidate ->
                    (candidate as? PerRequestRecord)?.id == record.id
                }
                if (!hasRemainingRecords) {
                    activeResponseStreams.remove(record.id)
                }
            }

            is PerWebSocketRecord -> {
                val hasRemainingRecords = records.any { candidate ->
                    candidate.perWebSocketRecord()?.id == record.id
                }
                if (!hasRemainingRecords) {
                    openWebSockets.remove(record.id)
                }
            }
        }
    }

    private fun completedRequestIds(): Set<String> {
        return records.mapNotNullTo(mutableSetOf()) { candidate ->
            when (candidate) {
                is ResponseReceived ->
                    candidate.id.takeUnless(activeResponseStreams::contains)

                is ResponseFinished -> candidate.id
                is RequestFailed -> candidate.id
                is ResponseStreamClosed -> candidate.id
                else -> null
            }
        }
    }

    private fun removeRequestConversation(requestId: String): Boolean {
        return removeRecords { candidate ->
            (candidate as? PerRequestRecord)?.id == requestId
        }
    }

    private fun removeWebSocketConversation(webSocketId: String): Boolean {
        return removeRecords { candidate ->
            candidate.perWebSocketRecord()?.id == webSocketId
        }
    }

    private inline fun removeRecords(predicate: (NetworkEventRecord) -> Boolean): Boolean {
        val iterator = records.iterator()
        var removedAny = false
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (predicate(record)) {
                iterator.remove()
                onRecordRemoved(record)
                removedAny = true
            }
        }
        return removedAny
    }

    private fun evictExpiredRecords(cutoff: Long) {
        val iterator = records.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (record is TimedRecord && record.tWallMs < cutoff) {
                iterator.remove()
                onRecordRemoved(record)
            } else {
                break
            }
        }
    }

    private fun onRecordRemoved(record: NetworkEventRecord) {
        sequenceByRecord.remove(record)
        subtractApproxBytes(record)
        updateConversationStateOnRemove(record)
        maybeEvictBodiesFor(record)
    }

    private fun maybeEvictBodiesFor(record: NetworkEventRecord) {
        val requestRecord = record as? PerRequestRecord ?: return
        val requestId = requestRecord.id
        val hasRemainingRequestRecords = records.any { candidate ->
            (candidate as? PerRequestRecord)?.id == requestId
        }
        if (hasRemainingRequestRecords) return
        removeRequestBody(requestId)
        removeResponseBody(requestId)
    }

    private fun upsertRequestBody(
        requestId: String,
        body: String,
        encoding: String?,
    ) {
        val captured = CapturedBody(body = body, encoding = encoding)
        val previous = requestBodiesById.put(requestId, captured)
        if (previous != null) {
            approxBytes -= estimateBodyEntrySize(requestId, previous)
        }
        approxBytes += estimateBodyEntrySize(requestId, captured)
    }

    private fun upsertResponseBody(
        requestId: String,
        body: String,
        encoding: String?,
    ) {
        val captured = CapturedBody(body = body, encoding = encoding)
        val previous = responseBodiesById.put(requestId, captured)
        if (previous != null) {
            approxBytes -= estimateBodyEntrySize(requestId, previous)
        }
        approxBytes += estimateBodyEntrySize(requestId, captured)
    }

    private fun removeRequestBody(requestId: String) {
        val removed = requestBodiesById.remove(requestId) ?: return
        approxBytes -= estimateBodyEntrySize(requestId, removed)
        if (approxBytes < 0) approxBytes = 0
    }

    private fun removeResponseBody(requestId: String) {
        val removed = responseBodiesById.remove(requestId) ?: return
        approxBytes -= estimateBodyEntrySize(requestId, removed)
        if (approxBytes < 0) approxBytes = 0
    }

    private fun estimateBodyEntrySize(requestId: String, capturedBody: CapturedBody): Long {
        val base = 48
        val payload = requestId.length + capturedBody.body.length + capturedBody.encoding.length
        return (base + payload).toLong()
    }

    private fun estimateSize(record: NetworkEventRecord): Long {
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

            is ResponseFinished -> 0
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

    private fun subtractApproxBytes(record: NetworkEventRecord) {
        approxBytes -= estimateSize(record)
        if (approxBytes < 0) approxBytes = 0
    }

    private fun sizeOfHeaders(headers: List<Header>): Int =
        headers.fold(0) { total, header ->
            total + header.name.length + header.value.length
        }
}

private val String?.length: Int get() = this?.length ?: 0
