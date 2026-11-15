package com.tresundios.walkathon

import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required so the Health
// Connect permission screen can be launched.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // A stable id for THIS phone + this app, used to bind the phone to one
        // walker profile. ANDROID_ID survives reinstalling the app (it only
        // changes on a factory reset), unlike an id the app generates itself.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "walkathon/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "getId") {
                    result.success(
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}
