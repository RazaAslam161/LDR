package com.miles.miles

import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
}
