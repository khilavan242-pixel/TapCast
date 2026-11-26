package com.tapcast.app

import android.Manifest
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.util.Rational
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/** Bridges Flutter <-> native: commands for the TV, an event stream with the TV's state, the file picker. */
class MainActivity : FlutterActivity() {

    private val main = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var pendingMediaResult: MethodChannel.Result? = null
    private var pipReady = false
    private var pipPlaying = false
    @Volatile private var resumed = false
    @Volatile private var keepWeb = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        requestNotificationPermission()
    }

    override fun onStart() {
        super.onStart()
        visible = true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "tapcast/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
                DlnaCaster.listener = { map -> main.post { eventSink?.success(map) } }
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                DlnaCaster.listener = null
            }
        })

        // Notification buttons while the phone itself plays go to the Flutter player.
        DlnaCaster.phoneControl = { action, value ->
            main.post { eventSink?.success(mapOf("type" to "phoneCtl", "action" to action, "value" to value)) }
        }

        MethodChannel(messenger, "tapcast/native").setMethodCallHandler(::onMethodCall)
    }

    private fun deviceFrom(m: Map<String, Any?>?): DlnaCaster.Device? {
        val control = m?.get("controlUrl") as? String ?: return null
        val type = m["serviceType"] as? String ?: return null
        return DlnaCaster.Device(
            m["name"] as? String ?: "TV",
            control,
            type,
            (m["renderUrl"] as? String)?.takeIf { it.isNotEmpty() },
            (m["renderType"] as? String)?.takeIf { it.isNotEmpty() },
        )
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "castDiscover" -> thread(name = "dlna-discover") {
                val list = try {
                    DlnaCaster.discover(applicationContext).map { it.toMap() }
                } catch (e: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            // A YouTube video: the phone looks up the stream, fills the queue and keeps it going.
            "castYoutube" -> {
                val device = deviceFrom(call.argument<Map<String, Any?>>("device"))
                val id = call.argument<String>("id")
                if (device == null || id == null) {
                    result.error("bad_args", "device and id are required", null)
                    return
                }
                val listUrl = call.argument<String>("listUrl")
                val shorts = call.argument<Boolean>("shorts") ?: false
                thread(name = "dlna-start") {
                    try {
                        if (!DlnaCaster.reachable(device)) {
                            main.post { result.error("unreachable", "Can't reach ${device.name}", null) }
                            return@thread
                        }
                        CastQueue.begin(applicationContext, device, id, listUrl, shorts = shorts)
                        main.post { result.success(true) }
                    } catch (e: Throwable) {
                        main.post { result.error("cast_failed", e.message ?: "Could not reach the TV", null) }
                    }
                }
            }

            // Opens a file or link with the phone's own player.
            "viewExternal" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.error("bad_args", "uri is required", null)
                    return
                }
                try {
                    val mime = call.argument<String>("mime")
                    val view = Intent(Intent.ACTION_VIEW).apply {
                        if (mime.isNullOrBlank()) setData(Uri.parse(uri)) else setDataAndType(Uri.parse(uri), mime)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(view, "Play with"))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("no_player", e.message ?: "No player found", null)
                }
            }

            "castQueue" -> result.success(DlnaCaster.queue())

            // ---- playing on the phone itself ----
            "phoneState" -> {
                val id = call.argument<String>("id") ?: ""
                val map = mapOf<String, Any?>(
                    "type" to "cast",
                    "status" to (call.argument<String>("status") ?: "playing"),
                    "device" to "this phone",
                    "title" to call.argument<String>("title"),
                    "uri" to (call.argument<String>("uri") ?: "https://www.youtube.com/watch?v=$id"),
                    "index" to (call.argument<Int>("index") ?: 0),
                    "count" to (call.argument<Int>("count") ?: 1),
                )
                DlnaCaster.phoneState = map
                if (!CastService.isRunning()) CastService.start(applicationContext, "this phone")
                CastService.update(applicationContext, map)
                result.success(null)
            }

            "phonePos" -> {
                CastService.progress(applicationContext, call.argument<Int>("pos") ?: 0, call.argument<Int>("dur") ?: 0)
                result.success(null)
            }

            "phoneEnd" -> {
                DlnaCaster.phoneState = null
                if (!DlnaCaster.castActive()) CastService.stop(applicationContext)
                result.success(null)
            }

            "setPhoneVideo" -> {
                pipReady = call.argument<Boolean>("ready") == true
                pipPlaying = call.argument<Boolean>("playing") == true
                keepWeb = call.argument<Boolean>("keep") == true
                applyPipParams()
                result.success(null)
            }

            // Files from the phone.
            "castPlay" -> {
                val device = deviceFrom(call.argument<Map<String, Any?>>("device"))
                val items = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                if (device == null || items.isEmpty()) {
                    result.error("bad_args", "device and items are required", null)
                    return
                }
                thread(name = "dlna-start") {
                    try {
                        if (!DlnaCaster.reachable(device)) {
                            main.post { result.error("unreachable", "Can't reach ${device.name}", null) }
                            return@thread
                        }
                        CastQueue.userStop()
                        DlnaCaster.start(
                            applicationContext,
                            device,
                            items.map {
                                DlnaCaster.Item(
                                    it["uri"] as? String ?: "",
                                    it["title"] as? String ?: "",
                                    it["mime"] as? String ?: "video/mp4",
                                    it["stream"] as? Boolean ?: false,
                                )
                            },
                        )
                        main.post { result.success(true) }
                    } catch (e: Throwable) {
                        main.post { result.error("cast_failed", e.message ?: "Could not reach the TV", null) }
                    }
                }
            }

            "castControl" -> {
                DlnaCaster.control(call.argument<String>("action") ?: "", call.argument<Int>("value") ?: 0)
                result.success(null)
            }

            "castState" -> result.success(DlnaCaster.state())

            "setShuffle" -> {
                CastQueue.shuffle = call.argument<Int>("mode") ?: 0
                result.success(null)
            }

            "exitApp" -> {
                AppExit.closeAll(applicationContext)
                result.success(null)
            }

            "pickMedia" -> {
                if (pendingMediaResult != null) {
                    result.error("busy", "File picker already open", null)
                    return
                }
                pendingMediaResult = result
                val pick = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                @Suppress("DEPRECATION")
                startActivityForResult(pick, REQUEST_MEDIA)
            }

            else -> result.notImplemented()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_MEDIA) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingMediaResult ?: return
        pendingMediaResult = null
        val picked = ArrayList<Uri>()
        data?.clipData?.let { clip -> for (i in 0 until clip.itemCount) picked.add(clip.getItemAt(i).uri) }
        data?.data?.let { if (picked.isEmpty()) picked.add(it) }
        if (resultCode != RESULT_OK || picked.isEmpty()) {
            pending.success(emptyList<Map<String, Any?>>())
            return
        }
        val list = picked.map { uri ->
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: Exception) {
                // a temporary grant is enough while casting
            }
            var name = uri.lastPathSegment ?: "Media"
            try {
                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { c -> if (c.moveToFirst()) name = c.getString(0) ?: name }
            } catch (e: Exception) {
                // keep the fallback name
            }
            val mime = contentResolver.getType(uri) ?: "video/mp4"
            mapOf("uri" to uri.toString(), "title" to name.substringBeforeLast('.'), "mime" to mime)
        }
        pending.success(list)
    }

    // ---- picture-in-picture (floating video window while the phone plays a video) ----

    private fun pipAction(icon: Int, label: String, code: Int, action: String): RemoteAction =
        RemoteAction(
            Icon.createWithResource(this, icon), label, label,
            PendingIntent.getBroadcast(
                this, code,
                Intent(this, CastActionReceiver::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )

    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setActions(
                listOf(
                    pipAction(R.drawable.ic_prev, "Previous", 21, CastService.ACTION_PREV),
                    if (pipPlaying) pipAction(R.drawable.ic_pause, "Pause", 22, CastService.ACTION_TOGGLE)
                    else pipAction(R.drawable.ic_play, "Play", 22, CastService.ACTION_TOGGLE),
                    pipAction(R.drawable.ic_next, "Next", 23, CastService.ACTION_NEXT),
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(pipReady)
        }
        return b.build()
    }

    private fun applyPipParams() {
        try {
            setPictureInPictureParams(pipParams())
        } catch (e: Exception) {
            // picture-in-picture is not available on this device
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters by itself (auto-enter); older versions are asked here.
        if (pipReady && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (e: Exception) {
                // not available
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        DlnaCaster.emitExternal(mapOf("type" to "pip", "on" to isInPictureInPictureMode))
        if (!isInPictureInPictureMode && pipReady) {
            // The window was closed with its X (not expanded back): stop, like the YouTube app.
            main.postDelayed({
                if (!resumed && pipReady) DlnaCaster.phoneControl?.invoke("stop", 0)
            }, 700)
        }
    }

    override fun onResume() {
        super.onResume()
        resumed = true
    }

    override fun onPause() {
        resumed = false
        super.onPause()
        keepWebRunning()
    }

    override fun onStop() {
        visible = false
        super.onStop()
        keepWebRunning()
    }

    private fun findWebViews(v: android.view.View, out: MutableList<android.webkit.WebView>) {
        if (v is android.webkit.WebView) out.add(v)
        if (v is android.view.ViewGroup) {
            for (i in 0 until v.childCount) findWebViews(v.getChildAt(i), out)
        }
    }

    /** A page that plays on the phone must keep running when the app leaves the screen. */
    private fun keepWebRunning() {
        if (!keepWeb) return
        try {
            val found = ArrayList<android.webkit.WebView>()
            findWebViews(window.decorView, found)
            for (w in found) {
                w.onResume()
                w.resumeTimers()
            }
        } catch (e: Exception) {
            // best effort
        }
    }

    /** While casting, the phone's volume keys change the TV volume. */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if ((keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN) &&
            DlnaCaster.canControlVolume()
        ) {
            DlnaCaster.control(if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) "volumeUp" else "volumeDown")
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    companion object {
        @Volatile var current: MainActivity? = null
        @Volatile var visible = false
        private const val REQUEST_MEDIA = 4202
    }
}
