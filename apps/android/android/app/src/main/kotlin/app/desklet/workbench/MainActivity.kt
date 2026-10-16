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
    }
    override fun onDestroy() { runtime?.close(); super.onDestroy() }
}
