package io.github.mateusguilherme.segue

import android.app.UiModeManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // What the app asks of Android itself (lib/television.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "segue/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> {
                    val uiMode = getSystemService(UiModeManager::class.java)
                    result.success(uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
                }
                else -> result.notImplemented()
            }
        }
    }
}
