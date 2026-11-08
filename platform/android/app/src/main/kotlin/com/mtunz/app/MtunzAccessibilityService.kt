package com.mtunz.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent

class MtunzAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: MtunzAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    fun dispatchRemoteGesture(
        action: String,
        x: Float,
        y: Float,
        endX: Float,
        endY: Float,
        durationMs: Long
    ): Boolean {
        val path = Path().apply {
            when (action) {
                "swipe" -> {
                    moveTo(x, y)
                    lineTo(endX, endY)
                }
                else -> {
                    moveTo(x, y)
                    lineTo(x + 1f, y + 1f)
                }
            }
        }
        val duration = if (action == "swipe") durationMs.coerceIn(80L, 1500L) else 80L
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, duration))
            .build()
        return dispatchGesture(gesture, null, null)
    }
}
