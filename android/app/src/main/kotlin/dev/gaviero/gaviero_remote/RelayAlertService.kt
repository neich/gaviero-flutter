package dev.gaviero.gaviero_remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

/**
 * Always-on agent alerts from gaviero-relay (replaces the ntfy app).
 *
 * A `specialUse` foreground service holds one HTTPS stream per relay
 * (`GET /v1/phone/stream?since=<id>`, NDJSON, keepalive every 25 s) and posts
 * a notification for every `notify` event. Tapping it opens
 * `gaviero-remote://open?host=&workspace=&conv=` — the deep link the app
 * already handles. Plain `HttpURLConnection` + `org.json`: no libraries.
 *
 * Config (written by [RelayAlerts] via the MethodChannel) lives in
 * SharedPreferences so the service and [BootReceiver] work with no Flutter
 * engine running.
 */
class RelayAlertService : Service() {
    private val connections = ConcurrentHashMap<String, HttpURLConnection>()
    @Volatile private var generation = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SERVICE, "Alert connection", NotificationManager.IMPORTANCE_MIN)
                .apply { description = "Keeps the connection that delivers agent alerts" },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALERTS, "Agent alerts", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "An agent finished or is waiting for you" },
        )
        // Reconnect at once when the network (or the VPN) changes instead of
        // waiting for the read timeout, as ntfy does.
        val cm = getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = dropConnections("network available")
            override fun onLost(network: Network) = dropConnections("network lost")
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (e: Exception) {
            Log.w(TAG, "no network callback: ${e.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val relays = loadRelays(this)
        if (relays.isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val ongoing = Notification.Builder(this, CHANNEL_SERVICE)
            .setContentTitle("Gaviero Remote")
            .setContentText("Listening for agent alerts")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID_ONGOING, ongoing, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID_ONGOING, ongoing)
        }
        // A new config replaces the running readers.
        val gen = ++generation
        dropConnections("reconfigured")
        for (relay in relays) {
            Thread({ readLoop(gen, relay) }, "relay-${relay.baseUrl}").start()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        generation++
        dropConnections("service stopped")
        networkCallback?.let {
            try { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } catch (_: Exception) {}
        }
        super.onDestroy()
    }

    private fun dropConnections(why: String) {
        if (connections.isNotEmpty()) Log.i(TAG, "dropping streams: $why")
        for (c in connections.values) {
            try { c.disconnect() } catch (_: Exception) {}
        }
    }

    private fun readLoop(gen: Int, relay: Relay) {
        var backoffMs = 2_000L
        while (gen == generation) {
            val started = System.currentTimeMillis()
            var conn: HttpURLConnection? = null
            try {
                val since = lastId(relay.baseUrl)
                // `epoch` lets a restarted relay (ids begin again at 1) ignore
                // a `since` that belongs to its previous run.
                val epoch = epoch(relay.baseUrl)
                val query = if (epoch.isEmpty()) "since=$since" else "since=$since&epoch=$epoch"
                conn = (URL("${relay.baseUrl}/v1/phone/stream?$query").openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15_000
                    readTimeout = 75_000 // keepalive lines arrive every 25 s
                    setRequestProperty("Authorization", "Bearer ${relay.secret}")
                    setRequestProperty("Accept", "application/x-ndjson")
                }
                connections[relay.baseUrl] = conn
                val code = conn.responseCode
                if (gen != generation) {
                    // Superseded while connecting (e.g. a reconfigure raced a
                    // boot/package-replaced start): leave it to the new reader.
                    return
                } else if (code != 200) {
                    Log.w(TAG, "relay ${relay.baseUrl} answered HTTP $code")
                } else {
                    Log.i(TAG, "stream open ${relay.baseUrl} since=$since")
                    BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                        while (gen == generation) {
                            val line = reader.readLine() ?: break
                            if (gen != generation) break // never post from a stale reader
                            handleLine(relay, line)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.i(TAG, "stream ${relay.baseUrl} ended: ${e.javaClass.simpleName} ${e.message ?: ""}")
            } finally {
                // Full teardown: never leave a half-open stream behind.
                connections.remove(relay.baseUrl, conn)
                try { conn?.disconnect() } catch (_: Exception) {}
            }
            if (gen != generation) return
            if (System.currentTimeMillis() - started > 60_000) backoffMs = 2_000L
            try { Thread.sleep(backoffMs) } catch (_: InterruptedException) {}
            backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
        }
    }

    private fun handleLine(relay: Relay, line: String) {
        if (line.isBlank()) return
        val event = try { JSONObject(line) } catch (_: Exception) { return }
        if (event.optString("type") == "presence") {
            // Always the first line. A new epoch means a new relay process
            // whose ids restart at 1: forget the old position before the
            // replay that follows.
            val epoch = event.optString("epoch")
            if (epoch.isNotEmpty() && epoch != epoch(relay.baseUrl)) {
                prefs(this).edit()
                    .putString("epoch:${relay.baseUrl}", epoch)
                    .putLong("since:${relay.baseUrl}", 0)
                    .apply()
                Log.i(TAG, "relay epoch $epoch — position reset")
            }
            return
        }
        if (event.optString("type") != "notify") return
        val id = event.optLong("id", 0)
        if (id <= lastId(relay.baseUrl)) return
        setLastId(relay.baseUrl, id)
        val machine = event.optString("machine")
        val workspace = event.optString("workspace_id")
        val conv = event.optString("conv")
        val waiting = event.optString("kind") == "agent_waiting"
        val name = workspaceName(this, machine, workspace)
        Log.i(TAG, "notify id=$id kind=${event.optString("kind")} workspace=$workspace")
        post(machine, workspace, conv, name, waiting)
    }

    private fun post(machine: String, workspace: String, conv: String, name: String, waiting: Boolean) {
        val link = Uri.Builder().scheme("gaviero-remote").authority("open")
            .appendQueryParameter("host", machine)
            .appendQueryParameter("workspace", workspace)
            .appendQueryParameter("conv", conv)
            .build()
        val tap = PendingIntent.getActivity(
            this,
            (machine + workspace + conv).hashCode(),
            Intent(Intent.ACTION_VIEW, link).setPackage(packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(this, CHANNEL_ALERTS)
            .setContentTitle(if (waiting) "$name · Agent needs you" else "$name · Agent finished")
            .setContentText(machine)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .build()
        // One notification per conversation: a newer event replaces it.
        getSystemService(NotificationManager::class.java)
            .notify("$machine|$workspace|$conv", if (waiting) 2 else 1, n)
    }

    private fun lastId(baseUrl: String): Long =
        prefs(this).getLong("since:$baseUrl", 0)

    private fun epoch(baseUrl: String): String =
        prefs(this).getString("epoch:$baseUrl", "") ?: ""

    private fun setLastId(baseUrl: String, id: Long) {
        prefs(this).edit().putLong("since:$baseUrl", id).apply()
    }

    data class Relay(val baseUrl: String, val secret: String)

    companion object {
        const val TAG = "GavieroRelay"
        private const val CHANNEL_SERVICE = "gaviero_relay_service"
        private const val CHANNEL_ALERTS = "gaviero_relay_alerts"
        private const val ID_ONGOING = 7301
        private const val PREFS = "gaviero_relay"
        const val KEY_CONFIG = "config"

        fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** Persist the config and (re)start or stop the service. */
        fun apply(ctx: Context, configJson: String) {
            prefs(ctx).edit().putString(KEY_CONFIG, configJson).apply()
            val intent = Intent(ctx, RelayAlertService::class.java)
            if (loadRelays(ctx).isEmpty()) ctx.stopService(intent) else ctx.startForegroundService(intent)
        }

        fun loadRelays(ctx: Context): List<Relay> {
            val raw = prefs(ctx).getString(KEY_CONFIG, null) ?: return emptyList()
            return try {
                val arr = JSONObject(raw).optJSONArray("relays") ?: return emptyList()
                (0 until arr.length()).mapNotNull { i ->
                    val o = arr.getJSONObject(i)
                    val base = o.optString("base_url").trimEnd('/')
                    val secret = o.optString("secret")
                    if (base.isEmpty() || secret.isEmpty()) null else Relay(base, secret)
                }
            } catch (_: Exception) {
                emptyList()
            }
        }

        fun workspaceName(ctx: Context, machine: String, workspace: String): String {
            val raw = prefs(ctx).getString(KEY_CONFIG, null) ?: return workspace
            return try {
                JSONObject(raw).optJSONObject("names")?.optString("$machine|$workspace")
                    ?.takeIf { it.isNotEmpty() } ?: workspace
            } catch (_: Exception) {
                workspace
            }
        }
    }
}
