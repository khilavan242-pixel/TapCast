package com.tapcast.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.IBinder
import androidx.core.content.ContextCompat
import java.net.URL
import kotlin.concurrent.thread

/**
 * Keeps the app alive while it is casting to a TV and shows a media notification
 * (picture, seek bar, previous / play-pause / next / stop) backed by a MediaSession.
 */
class CastService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val device = intent?.getStringExtra(EXTRA_DEVICE) ?: "TV"
        running = true
        instance = this
        if (lastState == null || lastState?.get("device") != device) {
            lastState = mapOf("status" to "loading", "device" to device)
        }
        applySession(applicationContext, lastState!!)
        acquireLocks()
        val notification = build(this, lastState!!)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        AppExit.swipedAway(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    private val handler = Handler(Looper.getMainLooper())
    private val idleRun = Runnable { AppExit.idle(applicationContext) }

    override fun onDestroy() {
        handler.removeCallbacks(idleRun)
        running = false
        instance = null
        releaseSession()
        try {
            wake?.takeIf { it.isHeld }?.release()
            wifi?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            // already released
        }
        wake = null
        wifi = null
        super.onDestroy()
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    /** Keeps the CPU and Wi-Fi awake so the next video is still queued with the screen off. */
    @Synchronized
    private fun acquireLocks() {
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tapcast:cast").apply {
                setReferenceCounted(false)
            }
        }
        // Re-arm for every new video so a long queue never outlives the lock's timeout.
        wake?.acquire(4 * 60 * 60 * 1000L)
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "tapcast:cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    /** Lets the CPU / Wi-Fi sleep while nothing plays (paused, stopped, error) to save battery. */
    @Synchronized
    private fun releaseLocks() {
        try {
            wake?.takeIf { it.isHeld }?.release()
            wifi?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            // already released
        }
        wake = null
        wifi = null
    }

    private fun follow(status: String) {
        handler.removeCallbacks(idleRun)
        if (status == "playing" || status == "loading" || status == "connecting" || status == "ended") {
            acquireLocks()
        } else {
            releaseLocks()
        }
        // Paused or stopped for 3 minutes: let everything go so TapCast does not stay in the background.
        if (status != "playing" && status != "loading" && status != "connecting") {
            handler.postDelayed(idleRun, 3 * 60 * 1000L)
        }
    }

    companion object {
        @Volatile private var instance: CastService? = null
        private const val CHANNEL_ID = "casting"
        private const val NOTIFICATION_ID = 1002
        private const val EXTRA_DEVICE = "device"

        const val ACTION_PREV = "com.tapcast.app.cast.PREV"
        const val ACTION_TOGGLE = "com.tapcast.app.cast.TOGGLE"
        const val ACTION_NEXT = "com.tapcast.app.cast.NEXT"
        const val ACTION_STOP = "com.tapcast.app.cast.STOP"

        @Volatile private var running = false
        fun isRunning(): Boolean = running
        @Volatile private var lastState: Map<String, Any?>? = null
        @Volatile private var thumbKey: String? = null
        @Volatile private var thumb: Bitmap? = null
        @Volatile private var thumbLoading: String? = null
        @Volatile private var positionSec = 0
        @Volatile private var durationSec = 0
        private var session: MediaSession? = null
        private var metaKey: String? = null
        private var shownUri: String? = null

        fun start(context: Context, deviceName: String) {
            val intent = Intent(context, CastService::class.java).putExtra(EXTRA_DEVICE, deviceName)
            try {
                if (running) context.startService(intent) else ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                // Android may refuse a background start; the cast itself keeps going
            }
        }

        fun stop(context: Context) {
            lastState = null
            context.stopService(Intent(context, CastService::class.java))
        }

        /** Refreshes the notification with the latest playback state. */
        fun update(context: Context, state: Map<String, Any?>) {
            val app = context.applicationContext
            val uri = state["uri"] as? String
            if (uri != shownUri) {
                shownUri = uri
                positionSec = 0
                durationSec = 0
            }
            lastState = state
            if (!running) return
            instance?.follow(state["status"] as? String ?: "loading")
            applySession(app, state)
            notifyNow(app, state)
            loadThumb(app, state)
        }

        /** Playback position from the TV, in seconds (drives the seek bar). */
        fun progress(context: Context, position: Int, duration: Int) {
            positionSec = position
            durationSec = duration
            val s = lastState ?: return
            if (running) applySession(context.applicationContext, s)
        }

        private fun notifyNow(app: Context, state: Map<String, Any?>) {
            try {
                val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, build(app, state))
            } catch (e: Exception) {
                // Notifications may be blocked; casting still works.
            }
        }

        private val idRegex = Regex("""(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})""")

        private fun keyFor(state: Map<String, Any?>): String? {
            val uri = state["uri"] as? String ?: return null
            return idRegex.find(uri)?.groupValues?.get(1) ?: uri
        }

        private fun loadThumb(app: Context, state: Map<String, Any?>) {
            val uri = state["uri"] as? String ?: return
            val key = keyFor(state) ?: return
            if (key == thumbKey || key == thumbLoading) return
            thumbLoading = key
            thumb = null
            val youtubeId = idRegex.find(uri)?.groupValues?.get(1)
            thread(name = "cast-thumb") {
                var bmp: Bitmap? = null
                try {
                    if (youtubeId != null) {
                        URL("https://i.ytimg.com/vi/$youtubeId/mqdefault.jpg").openStream().use {
                            bmp = BitmapFactory.decodeStream(it)
                        }
                    } else {
                        bmp = MediaThumbs.load(app, uri)
                    }
                } catch (e: Exception) {
                    // no picture, the notification still works
                }
                thumbKey = key
                if (thumbLoading == key) thumbLoading = null
                thumb = bmp
                if (bmp != null && running) {
                    lastState?.let { s ->
                        applySession(app, s)
                        notifyNow(app, s)
                    }
                }
            }
        }

        // ---- media session -------------------------------------------------------

        @Synchronized
        private fun ensureSession(app: Context): MediaSession {
            session?.let { return it }
            val s = MediaSession(app, "TapCastCast")
            s.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = DlnaCaster.control("resume")
                override fun onPause() = DlnaCaster.control("pause")
                override fun onSkipToNext() = DlnaCaster.control("next")
                override fun onSkipToPrevious() = DlnaCaster.control("previous")
                override fun onStop() = AppExit.closeAll(app)
                override fun onSeekTo(pos: Long) = DlnaCaster.control("seek", (pos / 1000).toInt())
                override fun onCustomAction(action: String, extras: Bundle?) {
                    if (action == "stop") AppExit.closeAll(app)
                }
            }, Handler(Looper.getMainLooper()))
            s.isActive = true
            session = s
            metaKey = null
            return s
        }

        @Synchronized
        private fun releaseSession() {
            try {
                session?.isActive = false
                session?.release()
            } catch (e: Exception) {
                // already released
            }
            session = null
            metaKey = null
        }

        @Synchronized
        private fun applySession(app: Context, state: Map<String, Any?>) {
            val s = ensureSession(app)
            val status = state["status"] as? String ?: "loading"
            val code = when (status) {
                "playing" -> PlaybackState.STATE_PLAYING
                "paused" -> PlaybackState.STATE_PAUSED
                "loading", "connecting" -> PlaybackState.STATE_BUFFERING
                else -> PlaybackState.STATE_STOPPED
            }
            val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_STOP or
                PlaybackState.ACTION_SEEK_TO
            s.setPlaybackState(
                PlaybackState.Builder()
                    .setActions(actions)
                    .addCustomAction(
                        PlaybackState.CustomAction.Builder("stop", "Stop", R.drawable.ic_stop).build(),
                    )
                    .setState(code, positionSec * 1000L, if (code == PlaybackState.STATE_PLAYING) 1f else 0f)
                    .build(),
            )
            val device = state["device"] as? String ?: "TV"
            val title = (state["title"] as? String)?.takeIf { it.isNotBlank() } ?: "Casting to $device"
            val art = if (keyFor(state) == thumbKey) thumb else null
            val key = "$title|$durationSec|${if (art != null) thumbKey else ""}"
            if (key != metaKey) {
                metaKey = key
                val meta = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, "Casting to $device")
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, durationSec * 1000L)
                if (art != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art)
                s.setMetadata(meta.build())
            }
        }

        // ---- notification --------------------------------------------------------

        private fun action(context: Context, code: Int, act: String): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(context, CastActionReceiver::class.java).setAction(act),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

        private fun button(context: Context, icon: Int, label: String, code: Int, act: String): Notification.Action =
            Notification.Action.Builder(Icon.createWithResource(context, icon), label, action(context, code, act)).build()

        @Suppress("DEPRECATION")
        private fun build(context: Context, state: Map<String, Any?>): Notification {
            ensureChannel(context)
            val device = state["device"] as? String ?: "TV"
            val status = state["status"] as? String ?: "loading"
            val title = (state["title"] as? String)?.takeIf { it.isNotBlank() } ?: "Casting to $device"
            val paused = status == "paused"

            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val b = Notification.Builder(context, CHANNEL_ID)
            val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
            session?.let { style.setMediaSession(it.sessionToken) }
            b.setSmallIcon(R.drawable.ic_stat_tapcast)
                .setContentTitle(title)
                .setContentText(if (status == "loading") "Starting on $device..." else "Casting to $device")
                .setSubText(device)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(button(context, R.drawable.ic_prev, "Previous", 1, ACTION_PREV))
                .addAction(
                    if (paused) button(context, R.drawable.ic_play, "Play", 2, ACTION_TOGGLE)
                    else button(context, R.drawable.ic_pause, "Pause", 2, ACTION_TOGGLE),
                )
                .addAction(button(context, R.drawable.ic_next, "Next", 3, ACTION_NEXT))
                .addAction(button(context, R.drawable.ic_close, "Close", 4, ACTION_STOP))
                .setStyle(style)
            if (keyFor(state) == thumbKey) thumb?.let { b.setLargeIcon(it) }
            return b.build()
        }

        private fun ensureChannel(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Casting", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Controls shown while playing on a TV"
                        setShowBadge(false)
                    },
                )
            }
        }
    }
}
