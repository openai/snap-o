package com.openai.snapo.tweaks.internal

import com.openai.snapo.tweaks.TweakColorValue
import com.openai.snapo.tweaks.toTweakColorValue
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal

class TweakValidationTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `integer updates respect their minimum maximum and step`() {
        val descriptor = TweakDescriptor(
            name = "Validation numeric bounds",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
            step = 2,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 18))

        assertEquals(18, state.value)
        assertInvalidUpdate(descriptor.name, -2)
        assertInvalidUpdate(descriptor.name, 50)
        assertInvalidUpdate(descriptor.name, 17)
        assertEquals(18, state.value)
    }

    @Test
    fun `an integer step without a minimum is relative to its default`() {
        val descriptor = TweakDescriptor(
            name = "Validation default-relative integer step",
            type = TweakType.INT,
            default = 5,
            step = 2,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 7))

        assertEquals(7, state.value)

        TweakRegistry.update(mapOf(descriptor.name to descriptor.default))

        assertEquals(5, state.value)
        assertInvalidUpdate(descriptor.name, 6)
        assertEquals(5, state.value)
    }

    @Test
    fun `a floating point step without a minimum is relative to its default`() {
        val descriptor = TweakDescriptor(
            name = "Validation default-relative floating point step",
            type = TweakType.FLOAT,
            default = 0.3f,
            step = 0.2f,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 0.5))

        assertEquals(0.5f, state.value)

        TweakRegistry.update(mapOf(descriptor.name to descriptor.default))

        assertEquals(0.3f, state.value)
        assertInvalidUpdate(descriptor.name, 0.4)
    }

    @Test
    fun `a step with a minimum is relative to the minimum`() {
        val descriptor = TweakDescriptor(
            name = "Validation minimum-relative step",
            type = TweakType.INT,
            default = 6,
            min = 2,
            max = 12,
            step = 2,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 8))

        assertEquals(8, state.value)
        assertInvalidUpdate(descriptor.name, 7)
        assertEquals(8, state.value)
    }

    @Test
    fun `a default must align with its minimum and step`() {
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "Validation unaligned default",
                    type = TweakType.INT,
                    default = 5,
                    min = 0,
                    step = 2,
                ),
            )
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `integer tweaks reject fractional and overflowing values`() {
        val descriptor = TweakDescriptor(
            name = "Validation integer type",
            type = TweakType.INT,
            default = 16,
        )
        val state = TweakRegistry.register(descriptor)

        assertInvalidUpdate(descriptor.name, 16.5)
        assertInvalidUpdate(descriptor.name, BigDecimal("16.5"))
        assertInvalidUpdate(descriptor.name, Int.MAX_VALUE.toLong() + 1)
        assertInvalidUpdate(descriptor.name, Int.MIN_VALUE.toLong() - 1)

        assertEquals(16, state.value)
    }

    @Test
    fun `floating point tweaks reject nonfinite values`() {
        val descriptor = TweakDescriptor(
            name = "Validation finite numbers",
            type = TweakType.FLOAT,
            default = 0f,
        )
        val state = TweakRegistry.register(descriptor)

        assertInvalidUpdate(descriptor.name, Float.NaN)
        assertInvalidUpdate(descriptor.name, Float.POSITIVE_INFINITY)
        assertInvalidUpdate(descriptor.name, Float.NEGATIVE_INFINITY)
        assertInvalidUpdate(descriptor.name, Double.NaN)
        assertInvalidUpdate(descriptor.name, Double.POSITIVE_INFINITY)
        assertInvalidUpdate(descriptor.name, Double.NEGATIVE_INFINITY)
        assertInvalidUpdate(descriptor.name, BigDecimal("1e100"))

        assertEquals(0f, state.value)
    }

    @Test
    fun `numeric literals reject excessive precision and scale`() {
        val unsupportedLiterals = listOf(
            "0e-3000000",
            "1e-3000000",
            "1e3000000",
            "9".repeat(TweakNumbers.MAX_PRECISION + 1),
        )

        unsupportedLiterals.forEach { literal ->
            val error = assertThrows(TweakUpdateException::class.java) {
                TweakNumbers.parse(literal)
            }

            assertEquals(422, error.statusCode)
        }
    }

    @Test
    fun `numeric literals reject excessive length before decimal parsing`() {
        val literal = "1".repeat(TweakNumbers.MAX_LITERAL_LENGTH + 1)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakNumbers.parse(literal)
        }

        assertEquals(422, error.statusCode)
    }

    @Test
    fun `numeric literals accept supported precision scale and length boundaries`() {
        val maximumPrecision = "9".repeat(TweakNumbers.MAX_PRECISION)
        val maximumLength = "1e+" + "0".repeat(TweakNumbers.MAX_LITERAL_LENGTH - 4) + "1"

        assertEquals(BigDecimal(maximumPrecision), TweakNumbers.parse(maximumPrecision))
        assertEquals(BigDecimal("1e-64"), TweakNumbers.parse("1e-64"))
        assertEquals(BigDecimal("1e64"), TweakNumbers.parse("1e64"))
        assertEquals(BigDecimal("1e1"), TweakNumbers.parse(maximumLength))
    }

    @Test
    fun `registry rejects excessive numeric scale before validating a step`() {
        val descriptor = TweakDescriptor(
            name = "Validation bounded default-relative floating point step",
            type = TweakType.FLOAT,
            default = 0.3f,
            step = 0.1f,
        )
        val state = TweakRegistry.register(descriptor)

        listOf(
            BigDecimal("0e-3000000"),
            BigDecimal("1e-3000000"),
            BigDecimal("1e3000000"),
            BigDecimal("9".repeat(TweakNumbers.MAX_PRECISION + 1)),
        ).forEach { value ->
            assertInvalidUpdate(descriptor.name, value)
            assertEquals(0.3f, state.value)
        }
    }

    @Test
    fun `floating point updates preserve the declared numeric type`() {
        val descriptor = TweakDescriptor(
            name = "Validation float type",
            type = TweakType.FLOAT,
            default = 0.25f,
            min = 0f,
            max = 1f,
            step = 0.25f,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 0.5))

        assertTrue(state.value is Float)
        assertEquals(0.5f, state.value)
    }

    @Test
    fun `floating point tweaks normalize integer JSON values to floats`() {
        val descriptor = TweakDescriptor(
            name = "Validation floating point integer input",
            type = TweakType.FLOAT,
            default = 0.25f,
            min = 0f,
            max = 4f,
            step = 0.25f,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to 2))

        assertTrue(state.value is Float)
        assertEquals(2f, state.value)

        TweakRegistry.update(mapOf(descriptor.name to BigDecimal("2.5")))

        assertTrue(state.value is Float)
        assertEquals(2.5f, state.value)

        TweakRegistry.update(mapOf(descriptor.name to BigDecimal("3")))

        assertTrue(state.value is Float)
        assertEquals(3f, state.value)
    }

    @Test
    fun `boolean tweaks accept only booleans`() {
        val descriptor = TweakDescriptor(
            name = "Validation boolean",
            type = TweakType.BOOLEAN,
            default = false,
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to true))

        assertEquals(true, state.value)
        assertInvalidUpdate(descriptor.name, "true")
        assertInvalidUpdate(descriptor.name, 1)
        assertEquals(true, state.value)
    }

    @Test
    fun `string tweaks accept strings and reset when the update is null`() {
        val descriptor = TweakDescriptor(
            name = "Validation string",
            type = TweakType.STRING,
            default = "before",
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to "after"))

        assertEquals("after", state.value)
        assertInvalidUpdate(descriptor.name, false)
        assertEquals("after", state.value)

        val reset = TweakRegistry.update(mapOf(descriptor.name to null)).single()

        assertEquals("before", state.value)
        assertEquals("before", reset.value)
        assertEquals(false, reset.modified)
    }

    @Test
    fun `colors accept rgb and rgba and normalize to uppercase`() {
        val descriptor = TweakDescriptor(
            name = "Validation color",
            type = TweakType.COLOR,
            default = "#2563EB".toTweakColorValue(),
        )
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to "#3b82f6"))

        assertEquals("#3B82F6", (state.value as TweakColorValue).wireValue)

        TweakRegistry.update(mapOf(descriptor.name to "#112233aa"))

        assertEquals("#112233AA", (state.value as TweakColorValue).wireValue)
    }

    @Test
    fun `colors reject malformed hexadecimal strings`() {
        val descriptor = TweakDescriptor(
            name = "Validation invalid color",
            type = TweakType.COLOR,
            default = "#2563EB".toTweakColorValue(),
        )
        val state = TweakRegistry.register(descriptor)

        assertInvalidUpdate(descriptor.name, "2563EB")
        assertInvalidUpdate(descriptor.name, "#123")
        assertInvalidUpdate(descriptor.name, "#GGGGGG")
        assertInvalidUpdate(descriptor.name, 0x2563EB)

        assertEquals("#2563EB", (state.value as TweakColorValue).wireValue)
    }

    @Test
    fun `integer and floating point tweaks expose distinct wire types`() {
        val integer = TweakDescriptor(
            name = "Validation integer wire type",
            type = TweakType.INT,
            default = 16,
        )
        val floatingPoint = TweakDescriptor(
            name = "Validation floating point wire type",
            type = TweakType.FLOAT,
            default = 0.25f,
        )
        val integerState = TweakRegistry.register(integer)
        val floatingPointState = TweakRegistry.register(floatingPoint)

        TweakRegistry.update(
            linkedMapOf(
                integer.name to BigDecimal("24"),
                floatingPoint.name to BigDecimal("0.5"),
            ),
        )

        assertEquals(
            listOf("int", "float"),
            TweakRegistry.snapshot().map {
                it.descriptor.type.wireName
            },
        )
        assertTrue(integerState.value is Int)
        assertEquals(24, integerState.value)
        assertTrue(floatingPointState.value is Float)
        assertEquals(0.5f, floatingPointState.value)
    }

    @Test
    fun `missing tweaks return a not found error`() {
        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(mapOf("Validation unknown tweak" to 16))
        }

        assertEquals(404, error.statusCode)
        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `invalid values do not partially apply a multi-tweak update`() {
        val padding = TweakDescriptor(
            name = "Validation atomic padding",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
        )
        val enabled = TweakDescriptor(
            name = "Validation atomic boolean",
            type = TweakType.BOOLEAN,
            default = false,
        )
        val paddingState = TweakRegistry.register(padding)
        val enabledState = TweakRegistry.register(enabled)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(
                linkedMapOf(
                    padding.name to 20,
                    enabled.name to "not a boolean",
                ),
            )
        }

        assertEquals(422, error.statusCode)
        assertEquals(16, paddingState.value)
        assertEquals(false, enabledState.value)
    }

    @Test
    fun `fractional integer updates do not partially apply floating point changes`() {
        val integer = TweakDescriptor(
            name = "Validation atomic fractional integer",
            type = TweakType.INT,
            default = 16,
        )
        val floatingPoint = TweakDescriptor(
            name = "Validation atomic floating point",
            type = TweakType.FLOAT,
            default = 0.25f,
        )
        val integerState = TweakRegistry.register(integer)
        val floatingPointState = TweakRegistry.register(floatingPoint)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(
                linkedMapOf(
                    floatingPoint.name to BigDecimal("2.5"),
                    integer.name to BigDecimal("16.5"),
                ),
            )
        }

        assertEquals(422, error.statusCode)
        assertTrue(integerState.value is Int)
        assertEquals(16, integerState.value)
        assertTrue(floatingPointState.value is Float)
        assertEquals(0.25f, floatingPointState.value)
    }

    @Test
    fun `unknown tweaks do not partially apply a multi-tweak update`() {
        val descriptor = TweakDescriptor(
            name = "Validation atomic known tweak",
            type = TweakType.INT,
            default = 16,
        )
        val state = TweakRegistry.register(descriptor)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(
                linkedMapOf(
                    descriptor.name to 20,
                    "Validation atomic missing tweak" to 24,
                ),
            )
        }

        assertEquals(404, error.statusCode)
        assertEquals(16, state.value)
    }

    @Test
    fun `invalid numeric descriptors are rejected before registration`() {
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "Validation zero step",
                    type = TweakType.INT,
                    default = 16,
                    step = 0,
                ),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "Validation reversed bounds",
                    type = TweakType.INT,
                    default = 16,
                    min = 32,
                    max = 8,
                ),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "Validation out of bounds default",
                    type = TweakType.INT,
                    default = 64,
                    min = 0,
                    max = 48,
                ),
            )
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `blank tweak names are rejected before registration`() {
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "  ",
                    type = TweakType.STRING,
                    default = "ignored",
                ),
            )
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `integer descriptors reject non-integer defaults and constraints`() {
        val base = TweakDescriptor(
            name = "Validation integer descriptor primitives",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
            step = 2,
        )

        listOf(
            base.copy(default = 16f),
            base.copy(default = 16L),
            base.copy(default = BigDecimal("16")),
            base.copy(min = 0f),
            base.copy(max = 48f),
            base.copy(step = 2f),
        ).forEach { descriptor ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(descriptor)
            }
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `floating point descriptors reject non-float defaults and constraints`() {
        val base = TweakDescriptor(
            name = "Validation floating point descriptor primitives",
            type = TweakType.FLOAT,
            default = 0.5f,
            min = 0f,
            max = 1f,
            step = 0.25f,
        )

        listOf(
            base.copy(default = 1),
            base.copy(default = 0.5),
            base.copy(default = BigDecimal("0.5")),
            base.copy(min = 0),
            base.copy(max = 1),
            base.copy(step = 0.25),
        ).forEach { descriptor ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(descriptor)
            }
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `floating point descriptors reject nonfinite defaults and constraints`() {
        val base = TweakDescriptor(
            name = "Validation finite floating point descriptor",
            type = TweakType.FLOAT,
            default = 0.5f,
            min = 0f,
            max = 1f,
            step = 0.25f,
        )

        listOf(
            base.copy(default = Float.NaN),
            base.copy(default = Float.POSITIVE_INFINITY),
            base.copy(min = Float.NEGATIVE_INFINITY),
            base.copy(max = Float.POSITIVE_INFINITY),
            base.copy(step = Float.POSITIVE_INFINITY),
        ).forEach { descriptor ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(descriptor)
            }
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `non-numeric descriptors reject numeric constraints`() {
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = "Validation constrained string",
                    type = TweakType.STRING,
                    default = "value",
                    min = 0,
                ),
            )
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    private fun assertInvalidUpdate(name: String, value: Any?) {
        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(mapOf(name to value))
        }

        assertEquals(422, error.statusCode)
    }
}
