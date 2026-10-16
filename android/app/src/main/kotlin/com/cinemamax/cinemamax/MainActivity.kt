package com.cinemamax.cinemamax

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Vom Player gesetzt: beim Verlassen der App automatisch Bild-in-Bild
    private var autoPip = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cinemamax/device").setMethodCallHandler { call, result ->
            when (call.method) {
                // Meldet Flutter, ob die App auf Android TV läuft (für TV-Oberfläche)
                "isTv" -> {
                    val ui = getSystemService(UI_MODE_SERVICE) as UiModeManager
                    result.success(
                        ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                            packageManager.hasSystemFeature("android.software.leanback")
                    )
                }
                "pipSupported" -> result.success(pipSupported())
                "pip" -> result.success(enterPip())
                "autoPip" -> {
                    autoPip = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pipSupported() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enterPip(): Boolean {
        if (!pipSupported()) return false
        return try {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        } catch (e: IllegalStateException) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip) enterPip()
    }
}
