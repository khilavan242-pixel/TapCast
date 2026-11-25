package com.tapcast.app

import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File

/** Builds the yt-dlp command line for a given kind and quality. Pure logic, unit-testable. */
object YtdlpOptions {

    /**
     * Format selector for MP4. Prefers H.264 video + AAC audio (plays on nearly
     * every TV, car stereo and old phone) and falls back to whatever is
     * available, so very high resolutions (VP9/AV1 only on YouTube) still work.
     * [maxHeight] == 0 means best available.
     */
    fun videoFormat(maxHeight: Int): String {
        if (maxHeight <= 0) {
            return "bv*[vcodec^=avc1]+ba[ext=m4a]/bv*+ba/b"
        }
        val h = "[height<=$maxHeight]"
        return "bv*$h[vcodec^=avc1]+ba[ext=m4a]/bv*$h+ba/b$h/b"
    }

    fun build(
        url: String,
        isAudio: Boolean,
        quality: Int,
        playlist: Boolean,
        workDir: File,
        coverArt: Boolean = false,
    ): YoutubeDLRequest {
        val r = YoutubeDLRequest(url)
        // File names that are legal on FAT32/exFAT pendrives and Windows.
        r.addOption("-o", File(workDir, "%(title).120B.%(ext)s").absolutePath)
        r.addOption("--windows-filenames")
        r.addOption(if (playlist) "--yes-playlist" else "--no-playlist")
        r.addOption("--no-mtime")
        r.addOption("--embed-metadata")
        r.addOption("--newline")
        r.addOption("--retries", "5")
        r.addOption("--fragment-retries", "5")
        r.addOption("--concurrent-fragments", "4")

        if (isAudio) {
            r.addOption("-f", "bestaudio/best")
            r.addOption("-x")
            r.addOption("--audio-format", "mp3")
            r.addOption("--audio-quality", "${if (quality > 0) quality else 320}K")
            if (coverArt) {
                // Album art from the video thumbnail, written into the MP3 tags.
                r.addOption("--embed-thumbnail")
                r.addOption("--convert-thumbnails", "jpg")
            }
        } else {
            r.addOption("-f", videoFormat(quality))
            r.addOption("--merge-output-format", "mp4")
        }
        return r
    }

    /** Turns raw yt-dlp stderr into something a person can act on. */
    fun friendlyError(raw: String?): String {
        val msg = raw?.trim().orEmpty()
        val line = msg.lines().lastOrNull { it.contains("ERROR", ignoreCase = true) } ?: msg.lines().lastOrNull().orEmpty()
        val lower = msg.lowercase()
        return when {
            "javascript runtime" in lower || "sign in to confirm" in lower || "http error 403" in lower ->
                "YouTube blocked this request. Open Settings, tap \"Update now\", then retry."
            "private video" in lower -> "This video is private."
            "video unavailable" in lower || "has been removed" in lower -> "This video is unavailable."
            "age" in lower && "confirm" in lower -> "This video is age-restricted and needs a signed-in account."
            "unable to resolve host" in lower || "network is unreachable" in lower || "timed out" in lower ->
                "No internet connection. Check your network and retry."
            "no space left" in lower -> "Not enough free storage."
            line.isBlank() -> "Download failed."
            else -> line.removePrefix("ERROR:").trim().take(300)
        }
    }
}
