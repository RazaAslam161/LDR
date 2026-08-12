package com.miles.miles

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Must extend FlutterFragmentActivity (NOT FlutterActivity): local_auth's
// biometric prompt requires a FragmentActivity host. With FlutterActivity,
// authenticate() throws `no_fragment_activity` and silently fails — which is
// why the app-lock could lock but never unlock.
class MainActivity : FlutterFragmentActivity() {

    private var secureFlagSet = false

    // Forwards hardware volume-key presses to Dart for the emergency-lock combo
    // + stealth-scrim dismiss. Android consumes volume keys before Flutter's
    // key pipeline sees them, so we must bridge them ourselves.
    private var volumeChannel: MethodChannel? = null

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> volumeChannel?.invokeMethod("volume", "up")
            KeyEvent.KEYCODE_VOLUME_DOWN -> volumeChannel?.invokeMethod("volume", "down")
        }
        // Return super so the system still adjusts the volume normally.
        return super.onKeyDown(keyCode, event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/volume_keys")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/secure_screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        runOnUiThread {
                            if (enable) {
                                window.setFlags(
                                    WindowManager.LayoutParams.FLAG_SECURE,
                                    WindowManager.LayoutParams.FLAG_SECURE
                                )
                                secureFlagSet = true
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                                secureFlagSet = false
                            }
                            result.success(null)
                        }
                    }
                    "isSecure" -> result.success(secureFlagSet)
                    else -> result.notImplemented()
                }
            }

        // Launcher disguise: exactly one <activity-alias> is enabled at a time,
        // and its manifest label + icon are what the launcher shows. This is the
        // only supported way to change an app's icon/name at runtime.
        //
        // Order matters and is not cosmetic: we ENABLE the new alias before
        // DISABLING any other. Doing it the other way round leaves a window
        // where no launcher component is enabled, and if the process is killed
        // in that window the app is gone from the launcher with no way back.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/disguise")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlias" -> {
                        val target = call.argument<String>("aliasId")
                        val all = call.argument<List<String>>("all")
                        if (target.isNullOrBlank() || all.isNullOrEmpty()) {
                            result.error("bad_args", "aliasId and all are required", null)
                            return@setMethodCallHandler
                        }
                        // Refuse anything not in the declared set — enabling a
                        // component that does not exist throws, and disabling
                        // everything else would strand the user.
                        if (!all.contains(target)) {
                            result.error("unknown_alias", "$target is not a declared alias", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val pm = packageManager
                            fun component(id: String) =
                                ComponentName(packageName, "$packageName.Alias$id")

                            // 1. Enable the new identity first.
                            pm.setComponentEnabledSetting(
                                component(target),
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                                PackageManager.DONT_KILL_APP
                            )
                            // 2. Only then retire the others.
                            all.filter { it != target }.forEach { id ->
                                pm.setComponentEnabledSetting(
                                    component(id),
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                                    PackageManager.DONT_KILL_APP
                                )
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // Leave whatever was enabled enabled. A failed swap
                            // must not cost the user their launcher entry.
                            result.error("switch_failed", e.message, null)
                        }
                    }
                    "currentAlias" -> {
                        val all = call.argument<List<String>>("all") ?: emptyList()
                        val active = all.firstOrNull { id ->
                            packageManager.getComponentEnabledSetting(
                                ComponentName(packageName, "$packageName.Alias$id")
                            ) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        }
                        result.success(active)
                    }
                    else -> result.notImplemented()
                }
            }

        // Everything the "Device Info" disguise shows that Dart cannot reach.
        // No new package and no new permission: battery is a sticky broadcast,
        // storage is StatFs, memory is ActivityManager, and the network kind
        // needs ACCESS_NETWORK_STATE, which this app already holds.
        //
        // Every value is the handset's own live state, which is what makes that
        // cover self-verifying — there is nothing here to fabricate.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/device_stats")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> try {
                        result.success(deviceStats())
                    } catch (e: Exception) {
                        // The Dart side renders a full screen without us; a
                        // cover that shows an error dialog is a cover that
                        // gets looked at twice.
                        result.error("stats_failed", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Full-screen-intent permission (Android 14 / API 34+). Below 34 it's
        // implicitly granted; from 34 the user must allow it in system settings.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "miles/fsi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canUseFullScreenIntent" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val nm = getSystemService(NotificationManager::class.java)
                            result.success(nm.canUseFullScreenIntent())
                        } else {
                            result.success(true)
                        }
                    }
                    "openSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun deviceStats(): Map<String, Any?> {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1

        val storage = StatFs(Environment.getDataDirectory().path)
        val memory = ActivityManager.MemoryInfo()
        getSystemService(ActivityManager::class.java).getMemoryInfo(memory)

        return mapOf(
            "batteryPercent" to if (level >= 0 && scale > 0) level * 100 / scale else -1,
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL),
            "storageTotal" to storage.totalBytes,
            "storageFree" to storage.availableBytes,
            "ramTotal" to memory.totalMem,
            "ramFree" to memory.availMem,
            "uptimeMs" to SystemClock.elapsedRealtime(),
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "buildId" to Build.DISPLAY,
            "network" to networkKind()
        )
    }

    private fun networkKind(): String {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return "Unknown"
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "Offline"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            else -> "Connected"
        }
    }
}
