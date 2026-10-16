package app.desklet.workbench

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
                else -> result.notImplemented()
            }
        }
    }
    override fun onDestroy() { runtime?.close(); super.onDestroy() }
}
