package com.tapcast.app

import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest

/** Lists a YouTube playlist, Mix or search without downloading anything (uses yt-dlp). */
object PlaylistLister {

    class Entry(val url: String, val title: String)

    fun list(url: String): List<Entry> {
        TapCastApp.awaitReady()
        val req = YoutubeDLRequest(url).apply {
            addOption("--flat-playlist")
            addOption("--yes-playlist")
            addOption("--no-warnings")
            addOption("--print", "%(webpage_url,url,id)s\t%(title)s")
        }
        val out = YoutubeDL.getInstance().execute(req, null) { _, _, _ -> }.out
        return out.lineSequence().mapNotNull { line ->
            val parts = line.split('\t', limit = 2)
            val ref = parts[0].trim()
            if (ref.isEmpty() || ref == "NA") return@mapNotNull null
            val title = parts.getOrNull(1).orEmpty().trim()
            if (title.startsWith("[Private video]") || title.startsWith("[Deleted video]")) return@mapNotNull null
            val link = if (ref.startsWith("http")) ref else "https://www.youtube.com/watch?v=$ref"
            Entry(link, if (title == "NA") "" else title)
        }.toList()
    }
}
