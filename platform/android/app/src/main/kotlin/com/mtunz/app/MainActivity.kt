package com.mtunz.app

import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "mtunz/native_control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> {
                        result.success(MtunzAccessibilityService.instance != null)
                    }
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }
                    "startMediaProjectionService" -> startProjectionService(result)
                    "stopMediaProjectionService" -> {
                        stopService(Intent(this, MtunzProjectionService::class.java))
                        result.success(null)
                    }
                    "dispatchGesture" -> {
                        val service = MtunzAccessibilityService.instance
                        if (service == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val args = call.arguments as? Map<*, *>
                        if (args == null) {
                            result.error("INVALID_ARGS", "Gesture payload missing", null)
                            return@setMethodCallHandler
                        }
                        val action = args["action"] as? String
                        if (action == null || (action != "tap" && action != "swipe")) {
                            result.error("INVALID_ACTION", "Only tap and swipe are supported", null)
                            return@setMethodCallHandler
                        }
                        val metrics = DisplayMetrics()
                        @Suppress("DEPRECATION")
                        (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
                        if (metrics.widthPixels <= 0 || metrics.heightPixels <= 0) {
                            result.error("INVALID_DISPLAY", "Could not read the device display size", null)
                            return@setMethodCallHandler
                        }
                        fun normalizedCoordinate(key: String): Float? {
                            val raw = (args[key] as? Number)?.toFloat() ?: return null
                            if (!raw.isFinite()) return null
                            return raw.coerceIn(0f, 1f)
                        }
                        val nx = normalizedCoordinate("x")
                        val ny = normalizedCoordinate("y")
                        val nex = if (action == "swipe") normalizedCoordinate("endX") else nx
                        val ney = if (action == "swipe") normalizedCoordinate("endY") else ny
                        if (nx == null || ny == null || nex == null || ney == null) {
                            result.error("INVALID_COORDINATES", "Gesture coordinates must be finite values from 0 to 1", null)
                            return@setMethodCallHandler
                        }
                        val maxX = (metrics.widthPixels - 1).coerceAtLeast(0).toFloat()
                        val maxY = (metrics.heightPixels - 1).coerceAtLeast(0).toFloat()
                        val x = nx * maxX
                        val y = ny * maxY
                        val endX = nex * maxX
                        val endY = ney * maxY
                        val duration = ((args["durationMs"] as? Number)?.toLong() ?: 350L).coerceIn(80L, 1500L)
                        result.success(service.dispatchRemoteGesture(action, x, y, endX, endY, duration))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startProjectionService(result: MethodChannel.Result) {
        val intent = Intent(this, MtunzProjectionService::class.java)
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            result.error("PROJECTION_SERVICE", error.message ?: "Could not start screen-sharing service", null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val settled = AtomicBoolean(false)
        lateinit var connection: ServiceConnection
        val timeout = Runnable {
            failProjectionStart(
                settled,
                handler,
                connection,
                intent,
                result,
                "Timed out waiting for the screen-sharing foreground service"
            )
        }
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (settled.compareAndSet(false, true)) {
                    handler.removeCallbacks(timeout)
                    try {
                        unbindService(this)
                    } catch (_: IllegalArgumentException) {
                    }
                    result.success(null)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                failProjectionStart(
                    settled, handler, this, intent, result,
                    "Screen-sharing foreground service disconnected before it was ready"
                )
            }

            override fun onBindingDied(name: ComponentName?) {
                failProjectionStart(
                    settled, handler, this, intent, result,
                    "Screen-sharing service binding died before it was ready"
                )
            }

            override fun onNullBinding(name: ComponentName?) {
                failProjectionStart(
                    settled, handler, this, intent, result,
                    "Screen-sharing service returned an empty binding"
                )
            }
        }

        try {
            val bound = bindService(intent, connection, BIND_AUTO_CREATE)
            if (!bound) {
                failProjectionStart(
                    settled, handler, connection, intent, result,
                    "Could not bind screen-sharing service"
                )
            } else if (!settled.get()) {
                handler.postDelayed(timeout, 10_000L)
            }
        } catch (error: Exception) {
            failProjectionStart(
                settled,
                handler,
                connection,
                intent,
                result,
                error.message ?: "Could not bind screen-sharing service"
            )
        }
    }

    private fun failProjectionStart(
        settled: AtomicBoolean,
        handler: Handler,
        connection: ServiceConnection,
        intent: Intent,
        result: MethodChannel.Result,
        message: String
    ) {
        if (!settled.compareAndSet(false, true)) return
        handler.removeCallbacksAndMessages(null)
        try {
            unbindService(connection)
        } catch (_: IllegalArgumentException) {
        }
        stopService(intent)
        result.error("PROJECTION_SERVICE", message, null)
    }

}
