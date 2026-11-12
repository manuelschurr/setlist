package de.schurr.setlist

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val documents = Documents(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Asked at launch rather than on the first rest: the request returns before the user answers, so a countdown posted right after it is dropped, and the Dart side never sends the same rest twice.
        if (savedInstanceState == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.schurr.setlist/rest").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.schurr.setlist/documents").setMethodCallHandler(documents)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!documents.onActivityResult(requestCode, resultCode, data)) super.onActivityResult(requestCode, resultCode, data)
    }
}
