package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import java.io.Closeable
import java.math.BigDecimal
import java.math.BigInteger

internal enum class TweakType(val wireName: String) {
    INT("int"),
    FLOAT("float"),
    BOOLEAN("boolean"),
    COLOR("color"),
    STRING("string"),
}

internal data class TweakDescriptor(
    val name: String,
    val type: TweakType,
    val default: Any,
    val min: Number? = null,
    val max: Number? = null,
    val step: Number? = null,
)

internal data class TweakSnapshot(
    val descriptor: TweakDescriptor,
    val value: Any,
)

internal open class TweakUpdateException(
    val statusCode: Int,
    message: String,
) : IllegalArgumentException(message)

internal class UnknownTweakException(name: String) :
    TweakUpdateException(404, "Unknown tweak: $name")

internal class InvalidTweakValueException(name: String, reason: String) :
    TweakUpdateException(422, "Invalid value for $name: $reason")

internal object TweakRegistry {
    private val lock = Any()
    private val tweaks = LinkedHashMap<String, RegisteredTweak>()
    private val observers = LinkedHashMap<Long, () -> Unit>()
    private var nextObserverId = 0L
    private val colorPattern = Regex("^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")

    fun register(descriptor: TweakDescriptor): State<Any> {
        var changed = false
        val state = synchronized(lock) {
            validateDescriptor(descriptor)

            val existing = tweaks[descriptor.name]
            if (existing != null) {
                require(existing.descriptor == descriptor) {
                    "Conflicting declarations for tweak: ${descriptor.name}"
                }
                existing.references += 1
                existing.state
            } else {
                val tweak = RegisteredTweak(
                    descriptor = descriptor,
                    state = mutableStateOf(descriptor.default),
                    references = 1,
                )
                tweaks[descriptor.name] = tweak
                changed = true
                tweak.state
            }
        }
        if (changed) notifyObservers()
        return state
    }

    fun unregister(name: String) {
        val changed = synchronized(lock) {
            val tweak = tweaks[name] ?: return@synchronized false
            tweak.references -= 1
            if (tweak.references == 0) {
                tweaks.remove(name)
                true
            } else {
                false
            }
        }
        if (changed) notifyObservers()
    }

    fun snapshot(): List<TweakSnapshot> = synchronized(lock) {
        tweaks.values.map { tweak ->
            TweakSnapshot(tweak.descriptor, tweak.state.value)
        }
    }

    fun update(values: Map<String, Any?>): List<TweakSnapshot> {
        var changed = false
        val snapshots = synchronized(lock) {
            val changes = values.map { (name, value) ->
                val tweak = tweaks[name]
                    ?: throw UnknownTweakException(name)
                tweak to validateValue(tweak.descriptor, value)
            }

            changes.forEach { (tweak, value) ->
                if (tweak.state.value != value) {
                    tweak.state.value = value
                    changed = true
                }
            }

            changes.map { (tweak, _) ->
                TweakSnapshot(tweak.descriptor, tweak.state.value)
            }
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

    fun containsChangedState(changed: Set<Any>): Boolean = synchronized(lock) {
        tweaks.values.any { it.state in changed }
    }

    fun clear() {
        val changed = synchronized(lock) {
            if (tweaks.isEmpty()) {
                false
            } else {
                tweaks.clear()
                true
            }
        }
        if (changed) notifyObservers()
    }

    private fun notifyObservers() {
        val current = synchronized(lock) { observers.values.toList() }
        current.forEach { it() }
    }

    private fun validateDescriptor(descriptor: TweakDescriptor) {
        require(descriptor.name.isNotBlank()) { "Tweak names must not be blank." }

        when (descriptor.type) {
            TweakType.INT, TweakType.FLOAT -> validateNumericDescriptor(descriptor)
            TweakType.BOOLEAN -> require(descriptor.default is Boolean) {
                "Boolean tweaks must have a boolean default: ${descriptor.name}"
            }

            TweakType.COLOR -> require(
                descriptor.default is String && colorPattern.matches(descriptor.default),
            ) {
                "Color tweaks must use #RRGGBB or #RRGGBBAA: ${descriptor.name}"
            }

            TweakType.STRING -> require(descriptor.default is String) {
                "String tweaks must have a string default: ${descriptor.name}"
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

            TweakType.STRING -> {
                value as? String ?: invalidValue(descriptor, "Expected a string.")
            }

            TweakType.COLOR -> {
                val color = value as? String
                    ?: invalidValue(descriptor, "Expected a color string.")
                if (!colorPattern.matches(color)) {
                    invalidValue(descriptor, "Expected #RRGGBB or #RRGGBBAA.")
                }
                color.uppercase()
            }
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

    private data class RegisteredTweak(
        val descriptor: TweakDescriptor,
        val state: MutableState<Any>,
        var references: Int,
    )
}
