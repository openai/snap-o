package com.openai.snapo.link.core

import android.app.Application
import android.content.pm.ApplicationInfo
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.SerializationStrategy
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.cancellation.CancellationException

/**
 * App-side server that accepts multiple desktop clients and delegates streaming to features.
 *
 * Transport:
 * ABSTRACT local UNIX domain socket → adb forward tcp:PORT localabstract:snapo_server_$pid
 */
class SnapOLinkServer(
    private val app: Application,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val config: SnapOLinkConfig = SnapOLinkConfig(),
) : Closeable {

    /** Name visible to `adb shell cat /proc/net/unix`. */
    val socketName: String = "snapo_server_${Process.myPid()}"
    // Security note: this binds in the Linux abstract namespace. Access is governed by SELinux
    // (connectto), not filesystem perms. Other apps will not be able to connect, but it is
    // reachable by ADB forward.

    // --- lifecycle ---
    @Volatile
    private var server: LocalServerSocket? = null

    @Volatile
    private var writerJob: Job? = null

    private val sessionsGuard = Any()
    private val sessions = LinkedHashMap<Long, SnapOLinkSession>()
    private val sessionIdCounter = AtomicLong(1L)
    private val linkContext by lazy {
        SnapOLinkContext(
            app = app,
            config = config,
            featureSinkProvider = { featureId -> sinkFor(featureId) },
        )
    }
    private val featureSinks = ConcurrentHashMap<String, LinkEventSink>()

    fun start() {
        if (!config.allowRelease &&
            app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0
        ) {
            Log.e(
                TAG,
                "Snap-O Link detected in a release build. Link server will NOT start. " +
                    "Release builds should use network-okhttp3-noop instead, " +
                    "or set snapo.allow_release=\"true\" if intentional."
            )
            return
        }

        if (server != null) return

        // Bind in ABSTRACT namespace; collisions are unlikely thanks to PID in the name.
        val server = LocalServerSocket(
            LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT).name
        )
        this.server = server
        writerJob = scope.launch(Dispatchers.IO) { acceptLoop(server) }
        SnapOLink.attach(this)
        scope.launch { emitAppIconIfAvailable() }
    }

    override fun close() {
        writerJob?.cancel()
        writerJob = null
        snapshotSessions().forEach { it.close() }
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
    }

    // ---- internals ----

    private fun acceptLoop(server: LocalServerSocket) {
        while (isActiveSafe()) {
            val socket = acceptSocketOrNull(server) ?: continue
            scope.launch(Dispatchers.IO) { handleAcceptedSocket(socket) }
        }
    }

    private fun acceptSocketOrNull(server: LocalServerSocket): LocalSocket? =
        try {
            server.accept()
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            null
        }

    private suspend fun handleAcceptedSocket(socket: LocalSocket) {
        val session = createSession(socket)
        registerSession(session)
        session.setOnCloseListener { closedSession ->
            unregisterSession(closedSession)
        }
        try {
            when (val result = session.run()) {
                is ClientHandshakeResult.Accepted -> Unit
                is ClientHandshakeResult.Rejected -> Log.w(
                    TAG,
                    "Rejected client connection for ${result.reason}"
                )
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            // swallow and continue accept loop
        } finally {
            session.close()
            try {
                socket.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun createSession(socket: LocalSocket): SnapOLinkSession =
        SnapOLinkSession(
            sessionIdCounter.getAndIncrement(),
            socket,
            linkContext,
            scope,
        )

    private fun registerSession(session: SnapOLinkSession) {
        synchronized(sessionsGuard) {
            sessions[session.id] = session
        }
    }

    private fun unregisterSession(session: SnapOLinkSession) {
        synchronized(sessionsGuard) {
            sessions.remove(session.id)
        }
    }

    private fun snapshotSessions(): List<SnapOLinkSession> =
        synchronized(sessionsGuard) { sessions.values.toList() }

    private fun findSession(clientId: Long): SnapOLinkSession? =
        synchronized(sessionsGuard) { sessions[clientId] }

    private fun isActiveSafe(): Boolean =
        (writerJob?.isActive != false)

    private fun sendHighPriorityRecordToAll(payload: LinkRecord) {
        val snapshot = snapshotSessions()
        snapshot.forEach { session ->
            if (session.state != SnapOLinkSessionState.ACTIVE) return@forEach
            if (!session.sendHighPriority(payload)) {
                session.close()
            }
        }
    }

    private fun emitAppIconIfAvailable() {
        val iconEvent = linkContext.loadAppIconIfAvailable() ?: return
        streamAppIcon(iconEvent)
    }

    private fun streamAppIcon(icon: AppIcon) {
        sendHighPriorityRecordToAll(icon)
    }

    private fun sinkFor(featureId: String): LinkEventSink =
        featureSinks.getOrPut(featureId) { FeatureEventSink(featureId) }

    private inner class FeatureEventSink(
        private val featureId: String,
    ) : LinkEventSink {
        override fun <T> send(
            payload: T,
            serializer: SerializationStrategy<T>,
            clientId: ClientId,
            priority: EventPriority,
        ) {
            val record = wrap(payload, serializer)
            when (clientId) {
                ClientId.All -> sendToAll(record, priority)
                is ClientId.Specific -> sendToClient(clientId.value, record, priority)
            }
        }

        private fun sendToAll(record: LinkRecord, priority: EventPriority) {
            val snapshot = snapshotSessions()
            snapshot.forEach { session ->
                if (session.state != SnapOLinkSessionState.ACTIVE) return@forEach
                if (!session.isFeatureOpened(featureId)) return@forEach
                if (!sendToSession(session, record, priority)) {
                    session.close()
                }
            }
        }

        private fun sendToClient(
            clientId: Long,
            record: LinkRecord,
            priority: EventPriority,
        ) {
            val session = findSession(clientId) ?: return
            if (session.state != SnapOLinkSessionState.ACTIVE) return
            if (!session.isFeatureOpened(featureId)) return
            if (!sendToSession(session, record, priority)) {
                session.close()
            }
        }

        private fun sendToSession(
            session: SnapOLinkSession,
            record: LinkRecord,
            priority: EventPriority,
        ): Boolean =
            when (priority) {
                EventPriority.High -> session.sendHighPriority(record)
                EventPriority.Low -> when (session.sendLowPriority(record)) {
                    SnapOLinkSession.LowPrioritySendResult.SENT -> true
                    SnapOLinkSession.LowPrioritySendResult.DROPPED_QUEUE_FULL -> {
                        val dropped = session.lowPriorityDroppedCount()
                        if (dropped == 1L || dropped % LowPriorityDropLogInterval == 0L) {
                            Log.w(
                                TAG,
                                "Dropped low-priority records for session ${session.id}; dropped=$dropped"
                            )
                        }
                        true
                    }

                    SnapOLinkSession.LowPrioritySendResult.SESSION_NOT_READY -> false
                }
            }

        private fun <T> wrap(payload: T, serializer: SerializationStrategy<T>): LinkRecord {
            val element = Ndjson.encodeToJsonElement(serializer, payload)
            return FeatureEvent(feature = featureId, payload = element)
        }
    }
    companion object {
        fun start(
            application: Application,
            scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            config: SnapOLinkConfig = SnapOLinkConfig(),
        ): SnapOLinkServer =
            SnapOLinkServer(application, scope, config)
                .also { it.start() }
    }
}

private const val TAG = "SnapOLink"
private const val LowPriorityDropLogInterval = 100L
