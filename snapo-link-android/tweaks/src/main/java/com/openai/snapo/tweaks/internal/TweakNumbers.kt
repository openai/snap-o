package com.openai.snapo.tweaks.internal

import java.math.BigDecimal

internal object TweakNumbers {
    const val MAX_LITERAL_LENGTH = 128
    const val MAX_PRECISION = 64
    const val MAX_SCALE = 64

    fun parse(literal: String): BigDecimal {
        if (literal.length > MAX_LITERAL_LENGTH) {
            invalidNumber()
        }

        val number = BigDecimal(literal)
        if (!isSupported(number)) {
            invalidNumber()
        }

        return number
    }

    fun isSupported(number: BigDecimal): Boolean =
        number.precision() <= MAX_PRECISION &&
            number.scale() in -MAX_SCALE..MAX_SCALE

    private fun invalidNumber(): Nothing =
        throw TweakUpdateException(
            statusCode = 422,
            message = "Numeric tweak value exceeds the supported precision or scale.",
        )
}
