package de.schurr.setlist

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var askedForNotifications = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.schurr.setlist/rest").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
                        askForNotifications()
                        RestAlarm.show(this, call.argument<String>("title")!!, call.argument<Number>("endsAtMs")!!.toLong())
                        result.success(null)
                    }
                    "cancel" -> {
                        RestAlarm.cancel(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("rest", e.toString(), null)
            }
        }
    }

    private fun askForNotifications() {
        if (askedForNotifications || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        askedForNotifications = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        }
    }
}
