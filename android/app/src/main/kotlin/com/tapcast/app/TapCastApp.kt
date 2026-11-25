package com.tapcast.app

import android.app.Application
import android.content.Context
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Initialises the bundled yt-dlp / FFmpeg once per process. Extraction of the
 * Python runtime takes a moment on first launch, so it happens off the main
 * thread and workers wait on [awaitReady] before running.
 *
 * YouTube changes often, so once a day (when enabled in Settings) the yt-dlp
 * engine is refreshed in the background. Workers wait up to 20 seconds for it,
 * so the first download of the day already uses the newest engine.
 */
class TapCastApp : Application() {

    override fun onCreate() {
        super.onCreate()
        thread(name = "ytdlp-init") {
            try {
                YoutubeDL.getInstance().init(this)
                FFmpeg.getInstance().init(this)
                initError = null
            } catch (t: Throwable) {
                Log.e(TAG, "yt-dlp init failed", t)
                initError = t
            } finally {
                ready.countDown()
            }
            maybeAutoUpdate(this)
        }
    }

    private fun maybeAutoUpdate(app: Application) {
        val due = initError == null &&
            AppSettings.autoUpdate(app) &&
            System.currentTimeMillis() - lastUpdate(app) > TimeUnit.HOURS.toMillis(24)
        if (!due) {
            updateDone.countDown()
            return
        }
        try {
            YoutubeDL.getInstance().updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
            markUpdated(app)
        } catch (t: Throwable) {
            // Offline or rate limited: not a problem, try again tomorrow.
            Log.w(TAG, "auto update skipped", t)
        } finally {
            updateDone.countDown()
        }
    }

    companion object {
        private const val TAG = "TapCastApp"
        private val ready = CountDownLatch(1)
        private val updateDone = CountDownLatch(1)

        @Volatile
        var initError: Throwable? = null
            private set

        private fun meta(c: Context) = c.applicationContext.getSharedPreferences("tapcast_engine", Context.MODE_PRIVATE)

        fun lastUpdate(c: Context): Long = meta(c).getLong("last_update", 0L)

        fun markUpdated(c: Context) {
            meta(c).edit().putLong("last_update", System.currentTimeMillis()).apply()
        }

        /** Blocks the calling (worker) thread until the engine is usable. */
        fun awaitReady() {
            ready.await()
            initError?.let {
                throw IllegalStateException("Download engine failed to start: ${describe(it)}", it)
            }
            updateDone.await(20, TimeUnit.SECONDS)
        }

        /**
         * Some errors (for example ExceptionInInitializerError) have no message of
         * their own, so show the class name and the chain of causes instead.
         */
        private fun describe(t: Throwable): String {
            val parts = mutableListOf<String>()
            var cur: Throwable? = t
            while (cur != null && parts.size < 3) {
                val msg = cur.message?.takeIf { it.isNotBlank() }
                parts += if (msg != null) "${cur.javaClass.simpleName}: $msg" else cur.javaClass.simpleName
                cur = cur.cause
            }
            return parts.joinToString(" <- ")
        }
    }
}
