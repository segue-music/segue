package io.github.mateusguilherme.segue

import android.app.UiModeManager
import android.content.res.Configuration
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity: the screen runs on audio_service's Flutter engine. With a plain
// FlutterActivity, audio_service started an engine of its own, and with it a second copy of the
// whole app, hidden, which connected to the hub as the same device.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // What the app asks of Android itself (lib/television.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "segue/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> {
                    val uiMode = getSystemService(UiModeManager::class.java)
                    result.success(uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
                }
                "deviceName" -> result.success(deviceName())
                else -> result.notImplemented()
            }
        }
    }

    /** The name the owner gave the device in the system settings, or else its maker and model. */
    private fun deviceName(): String {
        val named = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        } else {
            null
        }
        if (!named.isNullOrBlank()) return named
        val model = Build.MODEL
        return if (model.startsWith(Build.MANUFACTURER, ignoreCase = true)) model else "${Build.MANUFACTURER} $model"
    }
}
