package com.cinemamax.cinemamax

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Vom Player gesetzt: beim Verlassen der App automatisch Bild-in-Bild
    private var autoPip = false

    // Externer Link (Öffnen mit / Teilen), bis Flutter ihn abholt
    private var pendingLink: String? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Nach Drehen/Neuaufbau nicht erneut öffnen
        if (savedInstanceState == null) pendingLink = linkOf(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        linkOf(intent)?.let { channel?.invokeMethod("link", it) }
    }

    @Suppress("DEPRECATION")
    private fun linkOf(i: Intent?): String? = when (i?.action) {
        Intent.ACTION_VIEW -> i.dataString
        Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)
            ?: (i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.toString()
        else -> null
    }

    /// Liest höchstens [max] Bytes einer content://-Adresse als Text (Playlist erkennen/übernehmen).
    private fun readText(uri: String, max: Int, result: MethodChannel.Result) {
        Thread {
            try {
                val bytes = contentResolver.openInputStream(Uri.parse(uri))!!.use { s ->
                    val out = java.io.ByteArrayOutputStream()
                    val buf = ByteArray(65536)
                    while (out.size() < max) {
                        val n = s.read(buf, 0, minOf(buf.size, max - out.size()))
                        if (n < 0) break
                        out.write(buf, 0, n)
                    }
                    out.toByteArray()
                }
                runOnUiThread { result.success(String(bytes, Charsets.UTF_8)) }
            } catch (e: Exception) {
                runOnUiThread { result.error("read", e.message, null) }
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cinemamax/device")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                "installApk" -> {
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", java.io.File(call.arguments as String))
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install", e.message, null)
                    }
                }
                "readText" -> readText(call.argument<String>("uri") ?: "", call.argument<Int>("max") ?: 65536, result)
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
