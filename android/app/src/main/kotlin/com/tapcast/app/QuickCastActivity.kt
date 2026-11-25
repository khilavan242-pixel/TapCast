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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent?.getStringExtra(Intent.EXTRA_TEXT).orEmpty()
        val url = Regex("""https?://[^\s<>"']+""").find(shared)?.value
        videoId = CastQueue.videoId(url)
        if (videoId == null) {
            Toast.makeText(this, "No YouTube video found in what was shared", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        val list = url?.let { Regex("""[?&]list=([A-Za-z0-9_-]+)""").find(it)?.groupValues?.get(1) }
        listUrl = list?.takeIf { !it.startsWith("RD") }?.let { "https://www.youtube.com/playlist?list=$it" }

        val saved = AppSettings.lastDevice(this)
        if (saved != null) cast(saved) else pick()
    }

    private fun cast(device: DlnaCaster.Device) {
        val id = videoId ?: return finish()
        Toast.makeText(this, "Casting to ${device.name}…", Toast.LENGTH_SHORT).show()
        val app = applicationContext
        thread(name = "quick-cast") {
            try {
                CastQueue.begin(app, device, id, listUrl)
                runOnUiThread { finish() }
            } catch (e: Throwable) {
                runOnUiThread {
                    Toast.makeText(this, "Could not reach ${device.name}", Toast.LENGTH_LONG).show()
                    pick()
                }
            }
        }
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
