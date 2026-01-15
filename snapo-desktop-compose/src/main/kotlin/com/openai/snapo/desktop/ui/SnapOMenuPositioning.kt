package com.openai.snapo.desktop.ui

internal fun alignPopupAxis(
    position: Int,
    popupLength: Int,
    windowLength: Int,
    closeAffinity: Boolean = true,
): Int =
    when {
        popupLength >= windowLength -> alignStartEdges(popupLength, windowLength, closeAffinity)
        popupFitsBetweenPositionAndEndEdge(position, popupLength, windowLength, closeAffinity) ->
            alignPopupStartEdgeToPosition(position, popupLength, closeAffinity)
        popupFitsBetweenPositionAndStartEdge(position, popupLength, windowLength, closeAffinity) ->
            alignPopupEndEdgeToPosition(position, popupLength, closeAffinity)
        else -> alignEndEdges(popupLength, windowLength, closeAffinity)
    }

private fun popupFitsBetweenPositionAndStartEdge(
    position: Int,
    popupLength: Int,
    windowLength: Int,
    closeAffinity: Boolean,
): Boolean =
    if (closeAffinity) {
        popupLength <= position
    } else {
        windowLength - popupLength > position
    }

private fun popupFitsBetweenPositionAndEndEdge(
    position: Int,
    popupLength: Int,
    windowLength: Int,
    closeAffinity: Boolean,
): Boolean =
    popupFitsBetweenPositionAndStartEdge(position, popupLength, windowLength, !closeAffinity)

private fun alignPopupStartEdgeToPosition(
    position: Int,
    popupLength: Int,
    closeAffinity: Boolean,
): Int = if (closeAffinity) position else position - popupLength

private fun alignPopupEndEdgeToPosition(
    position: Int,
    popupLength: Int,
    closeAffinity: Boolean,
): Int = alignPopupStartEdgeToPosition(position, popupLength, !closeAffinity)

private fun alignStartEdges(popupLength: Int, windowLength: Int, closeAffinity: Boolean): Int =
    if (closeAffinity) 0 else windowLength - popupLength

private fun alignEndEdges(popupLength: Int, windowLength: Int, closeAffinity: Boolean): Int =
    alignStartEdges(popupLength, windowLength, !closeAffinity)
