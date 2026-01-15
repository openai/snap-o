package com.openai.snapo.desktop.adb

import com.openai.snapo.desktop.di.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.withContext

@SingleIn(AppScope::class)
@Inject
class DeviceTracker(
    private val adb: AdbExec,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val infoCache = HashMap<String, DeviceInfo>()

    val devices: StateFlow<List<Device>> = flow {
        suspend fun pause() = delay(300)

        while (true) {
            try {
                adb.trackDevices().collect { payload ->
                    emit(parseDevices(payload))
                }
                pause()
            } catch (t: CancellationException) {
                throw t
            } catch (_: Throwable) {
                emit(emptyList())
                pause()
            }
        }
    }.stateIn(
        scope,
        SharingStarted.WhileSubscribed(stopTimeoutMillis = 1_000),
        emptyList(),
    )

    val latestDevices: List<Device>
        get() = devices.value

    private suspend fun parseDevices(payload: String): List<Device> {
        val parsedRows = payload
            .lineSequence()
            .mapNotNull { parseDeviceRow(it) }
            .toList()

        // Fetch ro.* props once per device ID and cache.
        return parsedRows.map { (id, fields) ->
            val info = deviceInfoFor(id, fallbackModel = fields["model"])
            Device(
                id = id,
                model = info.model,
                androidVersion = info.version,
                vendorModel = info.vendorModel,
                manufacturer = info.manufacturer,
                avdName = info.avdName,
            )
        }
    }

    private fun parseDeviceRow(line: String): Pair<String, Map<String, String>>? {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return null

        val parts = trimmed.split(Regex("\\s+"))
        val id = parts.firstOrNull()?.trim().orEmpty()
        if (id.isEmpty()) return null

        if (parts.size >= 2) {
            val state = parts[1].lowercase()
            val invalidStates = listOf("offline", "unauthorized", "recovery", "authorizing")
            if (invalidStates.any(state::contains)) {
                return null
            }
        }

        val fields = LinkedHashMap<String, String>(6)
        for (part in parts.drop(1)) {
            val idx = part.indexOf(':')
            if (idx <= 0 || idx == part.lastIndex) continue
            val key = part.substring(0, idx)
            val value = part.substring(idx + 1)
            fields[key] = value
        }
        return id to fields
    }

    private suspend fun deviceInfoFor(id: String, fallbackModel: String?): DeviceInfo {
        infoCache[id]?.let { return it }

        val props = try {
            withContext(Dispatchers.IO) { adb.getProperties(deviceId = id, prefix = "ro.") }
        } catch (_: Throwable) {
            emptyMap()
        }

        fun cleanProp(key: String): String? = props[key]?.trim()?.takeIf { it.isNotEmpty() }

        val model = fallbackModel
            ?.replace('_', ' ')
            ?.takeIf { it.isNotBlank() }
            ?: cleanProp("ro.product.model")
            ?: "Unknown Model"

        val version = cleanProp("ro.build.version.release") ?: "Unknown API"

        val vendorModel = cleanProp("ro.product.vendor.model")
        val manufacturer = cleanProp("ro.product.vendor.manufacturer")
            ?: cleanProp("ro.product.manufacturer")

        val avdName = cleanProp("ro.boot.qemu.avd_name")
            ?.replace('_', ' ')

        val info = DeviceInfo(
            model = model,
            version = version,
            vendorModel = vendorModel,
            manufacturer = manufacturer,
            avdName = avdName,
        )
        infoCache[id] = info
        return info
    }

    private data class DeviceInfo(
        val model: String,
        val version: String,
        val vendorModel: String?,
        val manufacturer: String?,
        val avdName: String?,
    )
}
