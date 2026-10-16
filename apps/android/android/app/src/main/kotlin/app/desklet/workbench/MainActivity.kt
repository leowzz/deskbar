package app.desklet.workbench

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var runtime: ConnectionRuntime? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val connection = ConnectionRuntime(applicationContext)
        runtime = connection
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.desklet/events").setStreamHandler(connection)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.desklet/connection").setMethodCallHandler { call, result -> connection.call(call, result) }
        // Layout contains only local display preferences and stable resource IDs.
        // Keep it separate from the encrypted pairing credentials and cache.
        val preferences = getSharedPreferences("desklet-display", MODE_PRIVATE)
        // FULL_SENSOR follows the physical device even when Android's system
        // rotation toggle is off. Flutter's fullUser policy does not do this.
        requestedOrientation = if (preferences.getBoolean("rotationLocked", false)) {
            preferences.getInt("lockedOrientation", ActivityInfo.SCREEN_ORIENTATION_LOCKED)
        } else {
            ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.desklet/layout").setMethodCallHandler { call, result ->
            when (call.method) {
                "directory" -> result.success(filesDir.absolutePath)
                "loadTheme" -> result.success(preferences.getString("theme", "light").let { if (it == "dark") "dark" else "light" })
                "saveTheme" -> {
                    val theme = call.argument<String>("theme")
                    if (theme != "light" && theme != "dark") {
                        result.error("invalid_theme", "请选择浅色或暗色", null)
                    } else if (preferences.edit().putString("theme", theme).commit()) {
                        result.success(null)
                    } else {
                        result.error("save_failed", "未能保存主题，请重试", null)
                    }
                }
                "loadDisplayPreferences" -> result.success(mapOf(
                    "immersive" to preferences.getBoolean("immersive", true),
                    "rotationLocked" to preferences.getBoolean("rotationLocked", false)
                ))
                "saveDisplayPreferences" -> {
                    val immersive = call.argument<Boolean>("immersive")
                    val locked = call.argument<Boolean>("rotationLocked")
                    if (immersive == null || locked == null) {
                        result.error("invalid_display", "显示设置无效，请重试", null)
                    } else {
                        val editor = preferences.edit().putBoolean("immersive", immersive).putBoolean("rotationLocked", locked)
                        if (locked && (!preferences.getBoolean("rotationLocked", false) || !preferences.contains("lockedOrientation"))) {
                            editor.putInt("lockedOrientation", currentOrientation())
                        }
                        if (editor.commit()) result.success(null)
                        else result.error("save_failed", "未能保存显示设置，请重试", null)
                    }
                }
                "applyDisplayPreferences" -> {
                    val locked = call.argument<Boolean>("rotationLocked")
                    if (locked == null) {
                        result.error("invalid_display", "显示设置无效，请重试", null)
                    } else {
                        requestedOrientation = if (locked) {
                            preferences.getInt("lockedOrientation", ActivityInfo.SCREEN_ORIENTATION_LOCKED)
                        } else {
                            ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                        }
                        result.success(mapOf("requestedOrientation" to requestedOrientation))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    @Suppress("DEPRECATION")
    private fun currentOrientation(): Int {
        val rotation = windowManager.defaultDisplay.rotation
        val portrait = resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        val naturalPortrait = if (rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_180) portrait else !portrait
        return if (naturalPortrait) {
            when (rotation) {
                Surface.ROTATION_90 -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                Surface.ROTATION_180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                Surface.ROTATION_270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        } else {
            when (rotation) {
                Surface.ROTATION_90 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                Surface.ROTATION_180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                Surface.ROTATION_270 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
        }
    }
    override fun onDestroy() { runtime?.close(); super.onDestroy() }
}
