package com.tapcast.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import kotlin.concurrent.thread

/**
 * "Share -> TapCast": takes the YouTube link, starts it on the TV and closes at once,
 * so you stay in the YouTube app. Only the first time (no TV chosen yet) a small
 * list of TVs pops up over it.
 */
class QuickCastActivity : Activity() {

    private var videoId: String? = null
    private var listUrl: String? = null
    private var shorts = false
    private var sharedUrl = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent?.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        val url = Regex("""https?://[^\s<>"']+""").find(shared)?.value
        sharedUrl = url.orEmpty()
        videoId = CastQueue.videoId(url)
        shorts = url?.contains("/shorts/") == true
        val list = url?.let { Regex("""[?&]list=([A-Za-z0-9_-]+)""").find(it)?.groupValues?.get(1) }
        listUrl = list?.takeIf { !it.startsWith("RD") }?.let { "https://www.youtube.com/playlist?list=$it" }
        if (videoId == null && listUrl == null) {
            Toast.makeText(this, "No YouTube video found in what was shared", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        val saved = AppSettings.lastDevice(this)
        if (saved != null) cast(saved) else pick()
    }

    private fun cast(device: DlnaCaster.Device) {
        Toast.makeText(this, "Casting to ${device.name}…", Toast.LENGTH_SHORT).show()
        val app = applicationContext
        thread(name = "quick-cast") {
            try {
                if (!DlnaCaster.reachable(device)) {
                    runOnUiThread { offerPhone(device) }
                    return@thread
                }
                val id = videoId
                val list = listUrl
                if (id != null) CastQueue.begin(app, device, id, list, shorts = shorts)
                else if (list != null) CastQueue.beginPlaylist(app, device, list)
                runOnUiThread { finish() }
            } catch (e: Throwable) {
                runOnUiThread {
                    Toast.makeText(this, "Could not reach ${device.name}", Toast.LENGTH_LONG).show()
                    pick()
                }
            }
        }
    }

    /** The TV does not answer: offer to play on the phone instead. */
    private fun offerPhone(device: DlnaCaster.Device) {
        if (isFinishing) return
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Can't reach ${device.name}")
            .setMessage("Play on phone?")
            .setPositiveButton("Play on phone") { _, _ ->
                val id = videoId
                val link = if (id != null) "https://www.youtube.com/watch?v=$id" else sharedUrl
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (e: Exception) {
                    Toast.makeText(this, "Could not open the video", Toast.LENGTH_LONG).show()
                }
                finish()
            }
            .setNeutralButton("Choose another TV") { _, _ -> pick() }
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }

    private fun pick() {
        Toast.makeText(this, "Looking for TVs…", Toast.LENGTH_SHORT).show()
        thread(name = "quick-discover") {
            val found = try {
                DlnaCaster.discover(applicationContext)
            } catch (e: Throwable) {
                emptyList()
            }
            runOnUiThread {
                if (isFinishing) return@runOnUiThread
                if (found.isEmpty()) {
                    Toast.makeText(this, "No TV found on this Wi-Fi. Open TapCast to try again.", Toast.LENGTH_LONG).show()
                    finish()
                    return@runOnUiThread
                }
                AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                    .setTitle("Cast to")
                    .setItems(found.map { it.name }.toTypedArray()) { _, which ->
                        val d = found[which]
                        AppSettings.saveDevice(this, d)
                        cast(d)
                    }
                    .setOnCancelListener { finish() }
                    .show()
            }
        }
    }
}
