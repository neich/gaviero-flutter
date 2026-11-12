package dev.gaviero.gaviero_remote

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    // A debug-injected config (below) wins over the app's own
                    // until the app is reinstalled — the emulator check has no
                    // paired machines in the store.
                    val pinned = debuggable() &&
                        RelayAlertService.prefs(this).getBoolean(KEY_DEBUG_PINNED, false)
                    if (!pinned) RelayAlertService.apply(this, call.arguments as? String ?: "{}")
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> result.success(ignoringBatteryOptimizations())
                "requestBatteryExemption" -> {
                    if (!ignoringBatteryOptimizations()) {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName")),
                        )
                    }
                    result.success(null)
                }
                "openChannelSettings" -> {
                    // The system page for one alert channel, where its sound
                    // is chosen. Only our own alert channels are accepted.
                    val id = call.arguments as? String
                    if (id != RelayAlertService.CHANNEL_WAITING && id != RelayAlertService.CHANNEL_FINISHED) {
                        result.error("bad_channel", "unknown alert channel: $id", null)
                    } else {
                        RelayAlertService.ensureAlertChannels(this)
                        startActivity(
                            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                .putExtra(Settings.EXTRA_CHANNEL_ID, id),
                        )
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Both alert channels exist from first launch, so their sounds can be
        // set before the first alert (or with no relay configured at all).
        RelayAlertService.ensureAlertChannels(this)
        // Debug builds only: `adb shell am start -n dev.gaviero.gaviero_remote/.MainActivity
        // --es relay_config '<json>'` configures the alert service without a QR
        // scan (used by the emulator end-to-end check).
        if (debuggable()) {
            intent?.getStringExtra("relay_config")?.let {
                RelayAlertService.prefs(this).edit().putBoolean(KEY_DEBUG_PINNED, true).apply()
                RelayAlertService.apply(this, it)
            }
        }
    }

    private fun debuggable(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun ignoringBatteryOptimizations(): Boolean =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    companion object {
        const val CHANNEL = "dev.gaviero/relay_alerts"
        private const val KEY_DEBUG_PINNED = "debug_config_pinned"
    }
}
