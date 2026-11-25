package com.tapcast.app

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

/** Quick lookups straight from YouTube's own web API (one request, no engine start). */
object InnerTube {

    private const val UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    private fun post(endpoint: String, body: JSONObject): JSONObject {
        val conn = URL("https://www.youtube.com/youtubei/v1/$endpoint?prettyPrint=false")
            .openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 4000
            conn.readTimeout = 6000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("User-Agent", UA)
            conn.setRequestProperty("X-YouTube-Client-Name", "1")
            conn.setRequestProperty("X-YouTube-Client-Version", "2.20250310.01.00")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            if (conn.responseCode != 200) throw IOException("HTTP " + conn.responseCode)
            return JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
    }

    private fun context(): JSONObject =
        JSONObject().put(
            "client",
            JSONObject().put("clientName", "WEB").put("clientVersion", "2.20250310.01.00")
                .put("hl", "en").put("gl", "US"),
        )

    private fun titleOf(o: JSONObject?): String {
        if (o == null) return ""
        o.optString("simpleText").takeIf { it.isNotBlank() }?.let { return it }
        o.optString("content").takeIf { it.isNotBlank() }?.let { return it }
        val runs = o.optJSONArray("runs")
        return if (runs != null && runs.length() > 0) runs.optJSONObject(0)?.optString("text").orEmpty() else ""
    }

    private val idRe = Regex("^[A-Za-z0-9_-]{11}$")

    private fun walk(node: Any?, out: MutableList<PlaylistLister.Entry>) {
        when (node) {
            is JSONObject -> {
                node.optJSONObject("compactVideoRenderer")?.let { v ->
                    val id = v.optString("videoId")
                    if (idRe.matches(id)) out.add(PlaylistLister.Entry("https://www.youtube.com/watch?v=$id", titleOf(v.optJSONObject("title"))))
                }
                node.optJSONObject("lockupViewModel")?.let { v ->
                    val id = v.optString("contentId")
                    if (idRe.matches(id) && v.optString("contentType").contains("VIDEO")) {
                        val t = v.optJSONObject("metadata")?.optJSONObject("lockupMetadataViewModel")?.optJSONObject("title")
                        out.add(PlaylistLister.Entry("https://www.youtube.com/watch?v=$id", titleOf(t)))
                    }
                }
                val keys = node.keys()
                while (keys.hasNext()) walk(node.opt(keys.next()), out)
            }
            is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i), out)
        }
    }

    /** The "up next" videos YouTube lists beside / under a video. */
    fun related(id: String): List<PlaylistLister.Entry> {
        val body = JSONObject().put("videoId", id).put("context", context())
        val json = post("next", body)
        val found = mutableListOf<PlaylistLister.Entry>()
        walk(json.optJSONObject("contents"), found)
        val seen = HashSet<String>()
        return found.filter { e ->
            val vid = e.url.substringAfter("v=")
            vid != id && seen.add(vid)
        }.take(40)
    }
}
