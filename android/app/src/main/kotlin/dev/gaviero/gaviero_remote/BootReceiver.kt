package dev.gaviero.gaviero_remote

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restart the relay alert stream after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (RelayAlertService.loadRelays(context).isEmpty()) return
        context.startForegroundService(Intent(context, RelayAlertService::class.java))
    }
}
