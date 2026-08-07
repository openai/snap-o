package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.TweakColorValue
import com.openai.snapo.tweaks.toSnapOTweakValue
import com.openai.snapo.tweaks.toTweakColorValue
import java.io.Closeable
import java.math.BigDecimal
import java.math.BigInteger

internal enum class TweakType(val wireName: String) {
    INT("int"),
    FLOAT("float"),
    BOOLEAN("boolean"),
    COLOR("color"),
    STRING("string"),
    ENUM("enum"),
    ACTION("action"),
}

internal data class TweakDescriptor(
    val name: String,
    val type: TweakType,
    val default: Any,
    val min: Number? = null,
    val max: Number? = null,
    val step: Number? = null,
    val options: List<String> = emptyList(),
)

internal data class TweakSnapshot(
    val descriptor: TweakDescriptor,
    val value: Any,
    val modified: Boolean,
)

internal class UninitializedTweakSnapshotException : IllegalStateException()

internal interface ExternalTweakBacking : State<Any> {
    val name: String
    val descriptor: TweakDescriptor

    fun onValueChange(value: Any)

    fun onReset()

    fun isModified(): Boolean
}

internal interface SelectedTweakState : State<Any> {
    fun isSelected(owner: State<Any>): Boolean

    fun notifyChanged(owner: State<Any>)
}

internal open class TweakUpdateException(
    val statusCode: Int,
    message: String,
) : IllegalArgumentException(message)

internal class UnknownTweakException(name: String) :
    TweakUpdateException(404, "Unknown tweak: $name")

internal class InvalidTweakValueException(name: String, reason: String) :
    TweakUpdateException(422, "Invalid value for $name: $reason")

internal class UnknownTweakActionException(name: String) :
    TweakUpdateException(404, "Unknown action: $name")

internal class ConflictingTweakActionException(name: String) :
    TweakUpdateException(
        409,
        "Conflicting registrations for action: $name. Register the action once at its owner.",
    )

internal object TweakRegistry {
    private val lock = Any()
    private val tweaks = LinkedHashMap<String, RegisteredTweak>()
    private val observedTweakOrder = HashMap<String, Long>()
    private val adjustedTweaks = LinkedHashMap<TweakDescriptor, TweakSnapshot>()
    private val tweakStates = HashMap<TweakDescriptor, MutableState<Any>>()
    private val mutableActiveEntries = mutableStateOf<List<SnapOTweakEntry>>(emptyList())
    val activeEntries: State<List<SnapOTweakEntry>>
        get() = mutableActiveEntries
    private val observers = LinkedHashMap<Long, () -> Unit>()
    private var nextObserverId = 0L
    private var nextTweakOrder = 0L
    private val colorPattern = Regex("^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")

    fun stateFor(descriptor: TweakDescriptor): State<Any> = synchronized(lock) {
        tweakStates.getOrPut(descriptor) { mutableStateOf(descriptor.default) }
    }

    fun register(descriptor: TweakDescriptor): State<Any> = registerBacking(
        name = descriptor.name,
        descriptorFactory = { descriptor },
    )

    fun register(backing: ExternalTweakBacking): State<Any> = registerBacking(
        name = backing.name,
        descriptorFactory = { backing.descriptor },
        externalBacking = backing,
    )

    private fun registerBacking(
        name: String,
        descriptorFactory: () -> TweakDescriptor,
        externalBacking: ExternalTweakBacking? = null,
    ): State<Any> {
        var changed = false
        val state = synchronized(lock) {
            require(name.isNotBlank()) { "Tweak names must not be blank." }
            val ownedDescriptor = if (externalBacking == null) {
                descriptorFactory().also { descriptor ->
                    require(descriptor.type != TweakType.ACTION) {
                        "Actions must be registered with their composition owner: $name"
                    }
                    validateDescriptor(descriptor)
                }
            } else {
                null
            }

            val existing = tweaks[name]
            if (existing != null) {
                require(
                    existing.actionCallbacks == null &&
                        (existing.externalBacking != null) == (externalBacking != null),
                ) {
                    "Conflicting declarations for tweak: $name"
                }
                if (externalBacking == null) {
                    require(existing.descriptor == ownedDescriptor) {
                        "Conflicting declarations for tweak: $name"
                    }
                } else {
                    existing.addExternalBacking(externalBacking)
                }
                existing.references += 1
                existing.state
            } else {
                val tweak = RegisteredTweak(
                    name = name,
                    descriptorFactory = { ownedDescriptor ?: descriptorFactory() },
                    initialExternalBacking = externalBacking,
                )
                addRegisteredTweak(tweak)
                changed = true
                tweak.state
            }
        }
        if (changed) notifyObservers()
        return state
    }

    fun unregister(name: String, state: State<Any>? = null) {
        val changed = synchronized(lock) {
            val tweak = tweaks[name] ?: return@synchronized false
            val previousBacking = tweak.externalBacking
            if (previousBacking != null && !tweak.removeExternalBacking(state)) {
                return@synchronized false
            }
            if (state != null && previousBacking == null) return@synchronized false
            tweak.references -= 1
            if (tweak.references == 0) {
                if (previousBacking != null && tweak.wasAdjusted) {
                    val value = previousBacking.value
                    adjustedTweaks[tweak.descriptor] = TweakSnapshot(
                        descriptor = tweak.descriptor,
                        value = value,
                        modified = previousBacking.isModified(),
                    )
                }
                tweaks.remove(name)
                publishActiveEntries()
                true
            } else {
                previousBacking !== tweak.externalBacking
            }
        }
        if (changed) notifyObservers()
    }

    fun registerAction(
        name: String,
        onInvoke: () -> Unit,
    ): Closeable {
        val owner = Any()
        synchronized(lock) {
            val descriptor = TweakDescriptor(name = name, type = TweakType.ACTION, default = Unit)
            validateDescriptor(descriptor)

            val existing = tweaks[name]
            if (existing == null) {
                val action = RegisteredTweak(
                    name = name,
                    descriptorFactory = { descriptor },
                    actionCallbacks = linkedMapOf(owner to onInvoke),
                )
                addRegisteredTweak(action)
            } else {
                require(existing.actionCallbacks != null) {
                    "An action cannot share the name of a value tweak: $name"
                }
                val callbacks = requireNotNull(existing.actionCallbacks)
                callbacks[owner] = onInvoke
                updateActionConflict(existing)
            }
        }
        notifyObservers()
        return Closeable { unregisterAction(name, owner) }
    }

    private fun unregisterAction(
        name: String,
        owner: Any,
    ) {
        val changed = synchronized(lock) {
            val action = tweaks[name]
                ?.takeIf { it.descriptor.type == TweakType.ACTION }
                ?: return@synchronized false
            val callbacks = requireNotNull(action.actionCallbacks)
            if (callbacks.remove(owner) == null) return@synchronized false

            if (callbacks.isEmpty()) {
                tweaks.remove(name)
                publishActiveEntries()
            } else {
                updateActionConflict(action)
            }
            true
        }
        if (changed) notifyObservers()
    }

    fun invokeAction(name: String) {
        val callback = synchronized(lock) {
            val action = tweaks[name]
                ?.takeIf { it.descriptor.type == TweakType.ACTION }
                ?: throw UnknownTweakActionException(name)
            val callbacks = requireNotNull(action.actionCallbacks)
            if (callbacks.size != 1) throw ConflictingTweakActionException(name)

            callbacks.values.single()
        }
        callback()
    }

    fun snapshot(
        includeAdjusted: Boolean = false,
        cachedOnly: Boolean = false,
    ): List<TweakSnapshot> = synchronized(lock) {
        val activeSnapshots = tweaks.values.map { tweak ->
            tweak.snapshot(cachedOnly)
        }

        if (includeAdjusted) {
            (activeSnapshots + adjustedTweaks.values)
                .distinctBy(TweakSnapshot::descriptor)
                .sortedBy { snapshot -> observedTweakOrder.getValue(snapshot.descriptor.name) }
        } else {
            activeSnapshots
        }
    }

    fun update(values: Map<String, Any?>): List<TweakSnapshot> {
        var changed = false
        val snapshots = synchronized(lock) {
            val changes = values.map { (name, value) ->
                val tweak = tweaks[name]
                    ?: throw UnknownTweakException(name)
                val descriptor = tweak.descriptor
                if (descriptor.type == TweakType.ACTION) {
                    invalidValue(
                        descriptor,
                        "Actions cannot be patched. Invoke the registered action instead.",
                    )
                }
                tweak to value?.let { validateValue(descriptor, it) }
            }

            val changedTweaks = ArrayList<RegisteredTweak>()
            Snapshot.withMutableSnapshot {
                changes.forEach { (tweak, value) ->
                    val previous = tweak.snapshot(cachedOnly = false)
                    if (tweak.externalBacking != null ||
                        previous.value != (value ?: tweak.descriptor.default)
                    ) {
                        tweak.update(value)
                        if (tweak.snapshot(cachedOnly = false) != previous) {
                            changedTweaks.add(tweak)
                            changed = true
                        }
                    }
                }
            }
            val updatedSnapshots = changes.map { (tweak, _) ->
                tweak.snapshot(cachedOnly = false)
            }
            changedTweaks.forEach { tweak ->
                adjustedTweaks[tweak.descriptor] = tweak.snapshot(cachedOnly = false)
                tweak.wasAdjusted = true
            }
            updatedSnapshots
        }
        if (changed) notifyObservers()
        return snapshots
    }

    fun observeChanges(observer: () -> Unit): Closeable {
        val id = synchronized(lock) {
            val nextId = nextObserverId++
            observers[nextId] = observer
            nextId
        }
        return Closeable { synchronized(lock) { observers.remove(id) } }
    }

    fun clear() {
        val changed = synchronized(lock) {
            observedTweakOrder.clear()
            adjustedTweaks.clear()
            tweakStates.clear()
            nextTweakOrder = 0L

            if (tweaks.isEmpty()) {
                false
            } else {
                tweaks.clear()
                publishActiveEntries()
                true
            }
        }
        if (changed) notifyObservers()
    }

    private fun notifyObservers() {
        val current = synchronized(lock) { observers.values.toList() }
        current.forEach { it() }
    }

    private fun publishActiveEntries() {
        mutableActiveEntries.value = tweaks.values.map(RegisteredTweak::entry)
    }

    private fun addRegisteredTweak(tweak: RegisteredTweak) {
        val name = tweak.name
        val wasObserved = observedTweakOrder.containsKey(name)
        if (!wasObserved) {
            observedTweakOrder[name] = nextTweakOrder++
        }
        tweaks[name] = tweak
        if (wasObserved) {
            restoreObservedTweakOrder()
        }
        publishActiveEntries()
    }

    private fun updateActionConflict(action: RegisteredTweak) {
        val conflicted = requireNotNull(action.actionCallbacks).size > 1
        val current = action.state.value as SnapOTweakValue.Action
        if (current.conflicted != conflicted) {
            Snapshot.withMutableSnapshot {
                @Suppress("UNCHECKED_CAST")
                (action.state as MutableState<Any>).value = SnapOTweakValue.Action(conflicted)
            }
        }
    }

    private fun restoreObservedTweakOrder() {
        val orderedTweaks = tweaks.entries.sortedBy { entry ->
            observedTweakOrder.getValue(entry.key)
        }
        tweaks.clear()
        orderedTweaks.forEach { (name, tweak) ->
            tweaks[name] = tweak
        }
    }

    private fun validateDescriptor(descriptor: TweakDescriptor) {
        require(descriptor.name.isNotBlank()) { "Tweak names must not be blank." }

        when (descriptor.type) {
            TweakType.INT, TweakType.FLOAT -> validateNumericDescriptor(descriptor)
            TweakType.BOOLEAN -> require(descriptor.default is Boolean) {
                "Boolean tweaks must have a boolean default: ${descriptor.name}"
            }

            TweakType.COLOR -> require(
                descriptor.default is TweakColorValue &&
                    colorPattern.matches(descriptor.default.wireValue),
            ) {
                "Color tweaks must use #RRGGBB or #RRGGBBAA: ${descriptor.name}"
            }

            TweakType.STRING -> require(descriptor.default is String) {
                "String tweaks must have a string default: ${descriptor.name}"
            }

            TweakType.ENUM -> validateEnumDescriptor(descriptor)
            TweakType.ACTION -> require(descriptor.default === Unit) {
                "Actions must not declare a default value: ${descriptor.name}"
            }
        }

        if (descriptor.type != TweakType.ENUM) {
            require(descriptor.options.isEmpty()) {
                "Only enum tweaks can define selectable options: ${descriptor.name}"
            }
        }

        if (descriptor.type != TweakType.INT && descriptor.type != TweakType.FLOAT) {
            require(
                descriptor.min == null && descriptor.max == null && descriptor.step == null,
            ) {
                "Only numeric tweaks can define numeric constraints: ${descriptor.name}"
            }
        }
    }

    private fun validateEnumDescriptor(descriptor: TweakDescriptor) {
        require(descriptor.default is String) {
            "Enum tweaks must have an enum-name default: ${descriptor.name}"
        }
        require(descriptor.options.isNotEmpty()) {
            "Enum tweaks must define at least one option: ${descriptor.name}"
        }
        require(descriptor.options.all { option -> option.isNotBlank() }) {
            "Enum option values must not be blank: ${descriptor.name}"
        }
        require(descriptor.options.distinct().size == descriptor.options.size) {
            "Enum option values must be unique: ${descriptor.name}"
        }
        require(descriptor.default in descriptor.options) {
            "Enum tweak defaults must match a declared option: ${descriptor.name}"
        }
    }

    private fun validateNumericDescriptor(descriptor: TweakDescriptor) {
        validateNumericDescriptorTypes(descriptor)

        val default = descriptor.default as Number
        val defaultDecimal = default.toTweakDecimal()
            ?: throw IllegalArgumentException(
                "Numeric tweak defaults must be finite: ${descriptor.name}",
            )
        val minimum = descriptor.min?.let { constraint ->
            requireNotNull(constraint.toTweakDecimal()) {
                "Numeric tweak minimums must be finite: ${descriptor.name}"
            }
        }
        val maximum = descriptor.max?.let { constraint ->
            requireNotNull(constraint.toTweakDecimal()) {
                "Numeric tweak maximums must be finite: ${descriptor.name}"
            }
        }
        val increment = descriptor.step?.let { constraint ->
            requireNotNull(constraint.toTweakDecimal()) {
                "Numeric tweak steps must be finite: ${descriptor.name}"
            }
        }

        require(minimum == null || maximum == null || minimum <= maximum) {
            "Numeric tweak minimum must not exceed its maximum: ${descriptor.name}"
        }
        require(minimum == null || defaultDecimal >= minimum) {
            "Numeric tweak default is below its minimum: ${descriptor.name}"
        }
        require(maximum == null || defaultDecimal <= maximum) {
            "Numeric tweak default exceeds its maximum: ${descriptor.name}"
        }
        require(increment == null || increment > BigDecimal.ZERO) {
            "Numeric tweak steps must be positive: ${descriptor.name}"
        }
        require(
            minimum == null || increment == null ||
                defaultDecimal.subtract(minimum).remainder(increment)
                    .compareTo(BigDecimal.ZERO) == 0,
        ) {
            "Numeric tweak default must align with its minimum and step: ${descriptor.name}"
        }
    }

    private fun validateNumericDescriptorTypes(descriptor: TweakDescriptor) {
        val constraints = listOf(descriptor.min, descriptor.max, descriptor.step)

        when (descriptor.type) {
            TweakType.INT -> {
                require(descriptor.default is Int) {
                    "Integer tweaks must have a 32-bit integer default: ${descriptor.name}"
                }
                require(constraints.all { constraint -> constraint == null || constraint is Int }) {
                    "Integer tweak constraints must be 32-bit integers: ${descriptor.name}"
                }
            }

            TweakType.FLOAT -> {
                require(descriptor.default is Float) {
                    "Floating-point tweaks must have a float default: ${descriptor.name}"
                }
                require(
                    constraints.all { constraint -> constraint == null || constraint is Float },
                ) {
                    "Floating-point tweak constraints must be floats: ${descriptor.name}"
                }
            }

            else -> error("Tweak is not numeric: ${descriptor.name}")
        }
    }

    private fun validateValue(descriptor: TweakDescriptor, value: Any?): Any =
        when (descriptor.type) {
            TweakType.INT, TweakType.FLOAT -> validateNumericValue(descriptor, value)
            TweakType.BOOLEAN -> {
                value as? Boolean ?: invalidValue(descriptor, "Expected a boolean.")
            }

            TweakType.STRING, TweakType.ENUM -> validateStringValue(descriptor, value)
            TweakType.COLOR -> validateColorValue(descriptor, value)

            TweakType.ACTION -> invalidValue(
                descriptor,
                "Actions cannot be patched. Invoke the registered action instead.",
            )
        }

    private fun validateColorValue(descriptor: TweakDescriptor, value: Any?): TweakColorValue {
        val defaultColor = descriptor.default as TweakColorValue

        return when (value) {
            is TweakColorValue -> {
                val color = try {
                    value.color.toTweakColorValue()
                } catch (_: IllegalArgumentException) {
                    invalidValue(descriptor, "Expected a supported color.")
                }
                if (color.color == defaultColor.color) defaultColor else color
            }

            is String -> {
                if (!colorPattern.matches(value)) {
                    invalidValue(descriptor, "Expected #RRGGBB or #RRGGBBAA.")
                }
                val normalized = value.uppercase()
                if (normalized == defaultColor.wireValue) {
                    defaultColor
                } else {
                    normalized.toTweakColorValue()
                }
            }

            else -> invalidValue(descriptor, "Expected a color string.")
        }
    }

    private fun validateStringValue(descriptor: TweakDescriptor, value: Any?): String {
        val isEnum = descriptor.type == TweakType.ENUM
        val selection = value as? String
            ?: invalidValue(
                descriptor,
                if (isEnum) "Expected an enum name." else "Expected a string.",
            )
        if (isEnum && selection !in descriptor.options) {
            invalidValue(descriptor, "Expected one of the declared enum options.")
        }

        return selection
    }

    private fun validateNumericValue(descriptor: TweakDescriptor, value: Any?): Number {
        val number = value as? Number
            ?: invalidValue(descriptor, "Expected a number.")
        val decimal = number.toTweakDecimal()
            ?: invalidValue(descriptor, "Expected a finite number.")

        if (!TweakNumbers.isSupported(decimal)) {
            invalidValue(descriptor, "Numeric precision or scale exceeds the supported limit.")
        }

        validateNumericConstraints(descriptor, decimal)

        return normalizeNumericValue(descriptor, decimal)
    }

    private fun validateNumericConstraints(
        descriptor: TweakDescriptor,
        decimal: BigDecimal,
    ) {
        val minimum = descriptor.min?.toTweakDecimal()
        val maximum = descriptor.max?.toTweakDecimal()
        val increment = descriptor.step?.toTweakDecimal()

        if (minimum != null && decimal < minimum) {
            invalidValue(descriptor, "Value is below the minimum.")
        }
        if (maximum != null && decimal > maximum) {
            invalidValue(descriptor, "Value exceeds the maximum.")
        }
        if (increment != null) {
            val origin = minimum ?: requireNotNull(
                (descriptor.default as Number).toTweakDecimal(),
            )
            if (decimal.subtract(origin).remainder(increment).compareTo(BigDecimal.ZERO) != 0) {
                invalidValue(descriptor, "Value does not match the step.")
            }
        }
    }

    private fun normalizeNumericValue(
        descriptor: TweakDescriptor,
        decimal: BigDecimal,
    ): Number = when (descriptor.type) {
        TweakType.INT -> runCatching { decimal.intValueExact() }
            .getOrElse { invalidValue(descriptor, "Expected a 32-bit integer.") }

        TweakType.FLOAT -> decimal.toFloat().takeIf(Float::isFinite)
            ?: invalidValue(descriptor, "Expected a finite floating-point number.")

        else -> invalidValue(descriptor, "Unsupported numeric type.")
    }

    private fun invalidValue(descriptor: TweakDescriptor, reason: String): Nothing =
        throw InvalidTweakValueException(descriptor.name, reason)

    private fun Number.toTweakDecimal(): BigDecimal? = when (this) {
        is BigDecimal -> this
        is BigInteger -> BigDecimal(this)
        is Long, is Int, is Short, is Byte -> BigDecimal.valueOf(toLong())
        is Float -> if (isFinite()) BigDecimal(toString()) else null
        is Double -> if (isFinite()) BigDecimal(toString()) else null
        else -> runCatching { BigDecimal(toString()) }.getOrNull()
    }

    private class RegisteredTweak(
        val name: String,
        descriptorFactory: () -> TweakDescriptor,
        initialExternalBacking: ExternalTweakBacking? = null,
        val actionCallbacks: LinkedHashMap<Any, () -> Unit>? = null,
    ) {
        private val externalBackings = initialExternalBacking?.let { arrayListOf(it) }
        private val selectedExternalBacking = initialExternalBacking?.let { mutableStateOf(it) }
        private val externalSnapshot = initialExternalBacking?.let {
            mutableStateOf<TweakSnapshot?>(null)
        }

        val externalBacking: ExternalTweakBacking?
            get() = selectedExternalBacking?.value

        val descriptor: TweakDescriptor by lazy {
            (externalBacking?.descriptor ?: descriptorFactory()).also { descriptor ->
                require(descriptor.name == name) {
                    "Tweak descriptor name does not match its registration: $name"
                }
                if (externalBacking != null) validateDescriptor(descriptor)
            }
        }
        val state: State<Any> = when {
            selectedExternalBacking != null -> object : SelectedTweakState {
                override val value: Any
                    get() = snapshot(cachedOnly = false).value

                override fun isSelected(owner: State<Any>): Boolean =
                    selectedExternalBacking.value === owner

                override fun notifyChanged(owner: State<Any>) {
                    val selected = synchronized(lock) {
                        val active = tweaks[name] === this@RegisteredTweak && isSelected(owner)
                        if (active && requireNotNull(externalSnapshot).value != null) {
                            refreshExternalSnapshot()
                        }
                        active
                    }
                    if (selected) notifyObservers()
                }
            }
            actionCallbacks != null -> mutableStateOf(SnapOTweakValue.Action())
            else -> stateFor(descriptor)
        }
        var references = if (actionCallbacks == null) 1 else 0
        var wasAdjusted = false
        val entry = SnapOTweakEntry(
            name = name,
            value = derivedStateOf { descriptor.toSnapOTweakValue(state.value) },
            defaultValue = { descriptor.toSnapOTweakValue(descriptor.default) },
            isModified = when {
                actionCallbacks != null -> { { false } }
                selectedExternalBacking != null -> { { snapshot(cachedOnly = false).modified } }
                else -> { { state.value != descriptor.default } }
            },
        )

        fun snapshot(cachedOnly: Boolean): TweakSnapshot {
            val mirror = externalSnapshot
            if (mirror != null) {
                return mirror.value ?: if (cachedOnly) {
                    throw UninitializedTweakSnapshotException()
                } else {
                    refreshExternalSnapshot()
                }
            }

            val value = state.value
            return TweakSnapshot(
                descriptor,
                value,
                modified = actionCallbacks == null && value != descriptor.default,
            )
        }

        fun addExternalBacking(backing: ExternalTweakBacking) {
            requireNotNull(externalBackings).add(backing)
        }

        fun removeExternalBacking(state: State<Any>?): Boolean {
            val backings = externalBackings ?: return false
            val index = if (state == null) {
                0
            } else {
                backings.indexOfFirst { backing -> backing === state }
            }
            if (index < 0) return false

            backings.removeAt(index)
            if (index == 0 && backings.isNotEmpty()) {
                requireNotNull(selectedExternalBacking).value = backings.first()
                if (requireNotNull(externalSnapshot).value != null) {
                    refreshExternalSnapshot()
                }
            }
            return true
        }

        fun update(value: Any?) {
            val backing = externalBacking
            if (backing == null) {
                @Suppress("UNCHECKED_CAST")
                (state as MutableState<Any>).value = value ?: descriptor.default
            } else if (value == null) {
                backing.onReset()
                refreshExternalSnapshot()
            } else {
                backing.onValueChange(value)
                refreshExternalSnapshot()
            }
        }

        private fun refreshExternalSnapshot(): TweakSnapshot {
            val backing = requireNotNull(externalBacking)
            val value = backing.value
            val snapshot = TweakSnapshot(descriptor, value, backing.isModified())
            requireNotNull(externalSnapshot).value = snapshot
            return snapshot
        }
    }
}
