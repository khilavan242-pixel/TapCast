package com.tapcast.app

import android.content.Context
import android.util.Log
import kotlin.concurrent.thread

/**
 * Keeps the TV playing "up next" videos on its own, like the YouTube app. It runs
 * natively, so it works even when the screen is off and the app is not open.
 */
object CastQueue {

    private const val TAG = "CastQueue"
    private val idRe = Regex("""(?:v=|youtu\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})""")

    @Volatile private var app: Context? = null
    @Volatile private var device: DlnaCaster.Device? = null
    private val played = LinkedHashSet<String>()
    @Volatile private var seq = 0
    @Volatile private var queueing = false
    @Volatile private var continuing = false
    @Volatile private var extendedFor: String? = null
    @Volatile private var userStopped = true
    @Volatile private var wasActive = false
    @Volatile private var currentId: String? = null
    @Volatile private var currentTitle = ""
    @Volatile private var shortsMode = false

    /** 0 off, 1 random, 2 smart. */
    @Volatile var shuffle = 0

    fun videoId(url: String?): String? = url?.let { idRe.find(it)?.groupValues?.get(1) }

    /** True while the queue will start another video after the current one ends. */
    fun willContinue(): Boolean = !userStopped && device != null && currentId != null

    fun userStop() {
        userStopped = true
        seq++
    }

    /** Starts [id] on [dev] and fills the queue behind it. Call off the main thread. */
    fun begin(context: Context, dev: DlnaCaster.Device, id: String, listUrl: String?, keepHistory: Boolean = false, shorts: Boolean = false) {
        val appCtx = context.applicationContext
        app = appCtx
        device = dev
        val mine = ++seq
        if (!keepHistory) synchronized(played) { played.clear() }
        synchronized(played) { played.add(id) }
        extendedFor = null
        shortsMode = shorts
        userStopped = false
        currentId = id
        currentTitle = ""
        DlnaCaster.start(
            appCtx,
            dev,
            listOf(DlnaCaster.Item("https://www.youtube.com/watch?v=$id", "YouTube video", "video/mp4", true)),
        )
        thread(name = "cast-topup") { topUp(id, listUrl, mine) }
    }

    /** A playlist link with no single video chosen: plays it from the start. Call off the main thread. */
    fun beginPlaylist(context: Context, dev: DlnaCaster.Device, listUrl: String) {
        val entries = PlaylistLister.list(listUrl)
        val first = pick(entries).firstNotNullOfOrNull { videoId(it.url) }
            ?: throw IllegalStateException("That playlist is empty")
        begin(context, dev, first, listUrl)
    }

    private fun topUp(id: String, listUrl: String?, mine: Int) {
        var added = queueMore(id, listUrl, mine)
        var attempt = 0
        while (attempt < 2 && added == 0 && mine == seq && !userStopped) {
            attempt++
            try {
                Thread.sleep(3000)
            } catch (e: InterruptedException) {
                return
            }
            if (mine != seq) return
            added = queueMore(id, null, mine)
        }
    }

    private fun related(id: String, listUrl: String?): List<PlaylistLister.Entry> {
        // 1. An explicit playlist link.
        if (listUrl != null) {
            try {
                val e = PlaylistLister.list(listUrl)
                if (e.size > 1) return e
            } catch (t: Throwable) {
                Log.w(TAG, "playlist failed: " + t.message)
            }
        }
        // 2. Shorts: the next Shorts, back to back.
        if (shortsMode) {
            try {
                val e = InnerTube.shorts(id)
                if (e.isNotEmpty()) return e
            } catch (t: Throwable) {
                Log.w(TAG, "shorts failed: " + t.message)
            }
        }
        // 3. YouTube's own Mix for this video (the "Next:" list in the YouTube app).
        try {
            val e = InnerTube.mix(id)
            if (e.isNotEmpty()) return e
        } catch (t: Throwable) {
            Log.w(TAG, "mix (quick) failed: " + t.message)
        }
        // 4. What YouTube lists as "up next" (one quick request).
        try {
            val e = InnerTube.related(id)
            if (e.isNotEmpty()) return e
        } catch (t: Throwable) {
            Log.w(TAG, "related failed: " + t.message)
        }
        // 5. The video's Mix through yt-dlp.
        try {
            val e = PlaylistLister.list("https://www.youtube.com/watch?v=$id&list=RD$id")
            if (e.size > 1) return e
        } catch (t: Throwable) {
            Log.w(TAG, "mix failed: " + t.message)
        }
        // 6. A search for the title (keeps playing even when YouTube gives no related list).
        try {
            var title = currentTitle
            if (title.isBlank() || title == "YouTube video") {
                title = PlaylistLister.list("https://www.youtube.com/watch?v=$id").firstOrNull()?.title.orEmpty()
            }
            if (title.isNotBlank()) {
                val e = PlaylistLister.list("ytsearch20:" + title.trim())
                if (e.isNotEmpty()) return e
            }
        } catch (t: Throwable) {
            Log.w(TAG, "search failed: " + t.message)
        }
        return emptyList()
    }

    private fun pick(list: List<PlaylistLister.Entry>): List<PlaylistLister.Entry> {
        if (shuffle == 0 || list.size < 2) return list
        if (shuffle == 1) return list.shuffled()
        // Smart: keep the best matches near the front but mix their order a little.
        val head = list.take(12).shuffled()
        return head + list.drop(12)
    }

    private fun queueMore(id: String, listUrl: String?, mine: Int): Int {
        if (queueing) return 0
        queueing = true
        try {
            val entries = related(id, listUrl)
            if (mine != seq || userStopped) return 0
            val at = entries.indexOfFirst { videoId(it.url) == id }
            val after = if (at >= 0) entries.drop(at + 1) else entries
            val items = ArrayList<DlnaCaster.Item>()
            for (e in pick(after)) {
                val eid = videoId(e.url) ?: continue
                val isNew = synchronized(played) { played.add(eid) }
                if (!isNew) continue
                items.add(DlnaCaster.Item("https://www.youtube.com/watch?v=$eid", e.title.ifBlank { "YouTube video" }, "video/mp4", true))
                if (items.size >= (if (listUrl != null) 300 else 50)) break
            }
            if (items.isEmpty()) return 0
            DlnaCaster.append(items)
            return items.size
        } catch (t: Throwable) {
            Log.w(TAG, "queueMore failed: " + t.message)
            return 0
        } finally {
            queueing = false
        }
    }

    private fun playNextRelated(id: String) {
        if (continuing) return
        continuing = true
        try {
            val mine = seq
            val dev = device ?: return
            val ctx = app ?: return
            val entries = pick(related(id, null))
            if (mine != seq || userStopped) return
            for (e in entries) {
                val eid = videoId(e.url) ?: continue
                if (synchronized(played) { played.contains(eid) }) continue
                begin(ctx, dev, eid, null, keepHistory = true, shorts = shortsMode)
                return
            }
            // Nothing left to play: let the notification service go.
            CastService.stop(ctx)
        } catch (t: Throwable) {
            Log.w(TAG, "continue failed: " + t.message)
            app?.let { CastService.stop(it) }
        } finally {
            continuing = false
        }
    }

    /** Called for every state change from the TV session. */
    fun onState(map: Map<String, Any?>) {
        if (device == null) return
        val status = map["status"] as? String ?: return
        val id = videoId(map["uri"] as? String)
        if (status == "ended" && wasActive && !userStopped && currentId != null) {
            wasActive = false
            val cur = currentId!!
            thread(name = "cast-next") { playNextRelated(cur) }
            return
        }
        val active = status == "playing" || status == "paused" || status == "loading" || status == "connecting"
        if (!active) {
            if (status == "stopped" || status == "ended" || status == "error" || status == "idle") wasActive = false
            return
        }
        wasActive = true
        if (id == null) return
        if (id != currentId) {
            currentId = id
            currentTitle = ""
            synchronized(played) { played.add(id) }
        }
        val title = map["title"] as? String
        if (!title.isNullOrBlank() && title != "YouTube video") currentTitle = title
        val index = (map["index"] as? Number)?.toInt() ?: 0
        val count = (map["count"] as? Number)?.toInt() ?: 0
        if (status == "playing" && count > 0 && index >= count - 1 && extendedFor != id && !queueing) {
            extendedFor = id
            val mine = seq
            thread(name = "cast-more") { queueMore(id, null, mine) }
        }
    }
}
