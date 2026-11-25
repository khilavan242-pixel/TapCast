package com.tapcast.app

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Casts downloaded files to a DLNA / UPnP "MediaRenderer" on the same Wi-Fi,
 * such as a set-top box or smart TV.
 *
 *  1. [discover] finds renderers with SSDP and reads their AVTransport address.
 *  2. A tiny HTTP server on the phone serves the chosen files (with Range
 *     support), because the TV pulls the video from the phone.
 *  3. A session sends SetAVTransportURI + Play for each file and moves to the
 *     next one when the TV reports the track ended, so a list plays back to back.
 *
 * Everything uses plain sockets, so no extra libraries and no cleartext-traffic
 * switch are needed.
 */
object DlnaCaster {

    private const val TAG = "DlnaCaster"

    class Device(
        val name: String,
        val controlUrl: String,
        val serviceType: String,
        /** RenderingControl (volume) service, when the device has one. */
        val renderUrl: String? = null,
        val renderType: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "name" to name, "controlUrl" to controlUrl, "serviceType" to serviceType,
            "renderUrl" to renderUrl, "renderType" to renderType,
        )
    }

    /**
     * One thing to play. For a downloaded file [uri] is a content:// address and the
     * phone serves it. For a YouTube page ([stream] = true) [uri] is the page link:
     * the stream address is looked up with yt-dlp when its turn comes and the TV
     * fetches it straight from YouTube.
     */
    class Item(
        val uri: String,
        val title: String,
        val mime: String,
        val stream: Boolean = false,
    )

    /** Receives `{type:'cast', ...}` events; set by the Flutter channel. */
    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null

    @Volatile private var session: Session? = null

    // ---- public API ---------------------------------------------------------------

    /** Blocks for a few seconds while listening for devices. Call off the main thread. */
    fun discover(context: Context, waitMs: Int = 3500): List<Device> {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val lock = wifi?.createMulticastLock("tapcast-ssdp")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        val locations = LinkedHashSet<String>()
        try {
            DatagramSocket().use { sock ->
                sock.soTimeout = 400
                val msg = (
                    "M-SEARCH * HTTP/1.1\r\n" +
                        "HOST: 239.255.255.250:1900\r\n" +
                        "MAN: \"ssdp:discover\"\r\n" +
                        "MX: 2\r\n" +
                        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
                    ).toByteArray(Charsets.UTF_8)
                val group = InetAddress.getByName("239.255.255.250")
                for (i in 0 until 2) {
                    sock.send(DatagramPacket(msg, msg.size, group, 1900))
                    Thread.sleep(150)
                }
                val end = System.currentTimeMillis() + waitMs
                val buf = ByteArray(4096)
                val locationRx = Regex("(?im)^location:\\s*(\\S+)")
                while (System.currentTimeMillis() < end) {
                    try {
                        val p = DatagramPacket(buf, buf.size)
                        sock.receive(p)
                        val text = String(p.data, 0, p.length, Charsets.UTF_8)
                        locationRx.find(text)?.groupValues?.get(1)?.let { locations.add(it) }
                    } catch (e: SocketTimeoutException) {
                        // keep listening until the deadline
                    }
                }
            }
        } finally {
            lock?.release()
        }
        return locations.mapNotNull { describe(it) }.distinctBy { it.controlUrl }
    }

    /** Starts (or replaces) a cast session. Call off the main thread. */
    fun start(context: Context, device: Device, items: List<Item>) {
        stopSession()
        val app = context.applicationContext
        val ip = localIpFor(device.controlUrl)
        val server = MediaServer(app.contentResolver)
        val s = Session(app, device, CopyOnWriteArrayList(items), server, ip)
        session = s
        CastService.start(app, device.name)
        thread(name = "dlna-session") { s.run() }
    }

    /** pause | resume | next | previous | stop | seek (value = seconds) | volume (value = 0..100) | volumeUp | volumeDown */
    fun control(action: String, value: Int = 0) {
        val s = session ?: return
        if (action == "stop") CastQueue.userStop()
        thread(name = "dlna-control") { s.control(action, value) }
    }

    /** Stops the TV and waits for it (used when the app is being closed). Call off the main thread. */
    fun stopNow() {
        val s = session ?: return
        CastQueue.userStop()
        s.control("stop", 0)
    }

    /** Adds more items to the end of the running queue (used for "up next"). */
    fun append(items: List<Item>) {
        val s = session ?: return
        s.items.addAll(items)
        s.publishCurrent()
    }

    /** True while casting to a device whose volume can be set (used for the phone's volume keys). */
    fun canControlVolume(): Boolean = session?.device?.renderUrl != null

    fun state(): Map<String, Any?> = session?.toMap() ?: mapOf("type" to "cast", "status" to "idle")

    /** Finds a direct, ready-to-play address for a YouTube link. Call off the main thread. */
    /** Title, direct address and length (seconds) of a YouTube video, for the in-app player. */
    fun resolveForPlayer(pageUrl: String, legacy: Boolean, audioOnly: Boolean, maxHeight: Int): Triple<String, String, Int> {
        if (!legacy) {
            // Fastest way first (a single quick request); the slower ones below are the safety net.
            try {
                return resolveDirect(pageUrl, audioOnly, maxHeight)
            } catch (e: Exception) {
                Log.w("TapCast", "direct resolve failed: " + e.message)
            }
        }
        if (audioOnly) return resolveStream(pageUrl, true, 720)
        if (!legacy) {
            try {
                return resolveFast(pageUrl, maxHeight)
            } catch (e: Exception) {
                // fall back to the slower, more widely working way below
            }
        }
        return resolveStream(pageUrl, false, maxHeight)
    }

    /** One quick request to YouTube as the iOS app does; picks a streaming quality that saves data. */
    private fun resolveDirect(pageUrl: String, audioOnly: Boolean, maxHeight: Int): Triple<String, String, Int> {
        val id = Regex("(?:v=|youtu\\.be/|shorts/|embed/)([A-Za-z0-9_-]{11})").find(pageUrl)?.groupValues?.get(1)
            ?: throw IOException("no video id")
        val ua = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        val client = org.json.JSONObject()
            .put("clientName", "IOS").put("clientVersion", "20.10.4")
            .put("deviceMake", "Apple").put("deviceModel", "iPhone16,2")
            .put("osName", "iPhone").put("osVersion", "18.3.2.22D82")
            .put("hl", "en").put("gl", "US")
        val body = org.json.JSONObject().put("videoId", id)
            .put("contentCheckOk", true).put("racyCheckOk", true)
            .put("context", org.json.JSONObject().put("client", client))
        val conn = URL("https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false")
            .openConnection() as java.net.HttpURLConnection
        val text: String
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 4000
            conn.readTimeout = 5000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("User-Agent", ua)
            conn.setRequestProperty("X-YouTube-Client-Name", "5")
            conn.setRequestProperty("X-YouTube-Client-Version", "20.10.4")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            if (conn.responseCode != 200) throw IOException("player HTTP " + conn.responseCode)
            text = conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
        val j = org.json.JSONObject(text)
        val status = j.optJSONObject("playabilityStatus")?.optString("status")
        if (status != "OK") throw IOException("not playable: $status")
        val title = j.optJSONObject("videoDetails")?.optString("title").orEmpty().ifBlank { "Video" }
        val seconds = j.optJSONObject("videoDetails")?.optString("lengthSeconds")?.toIntOrNull() ?: 0
        val hls = j.optJSONObject("streamingData")?.optString("hlsManifestUrl").orEmpty()
        if (!hls.startsWith("http")) throw IOException("no streaming playlist")
        val c2 = URL(hls).openConnection() as java.net.HttpURLConnection
        val manifest: String
        try {
            c2.connectTimeout = 4000
            c2.readTimeout = 5000
            c2.setRequestProperty("User-Agent", ua)
            if (c2.responseCode != 200) throw IOException("playlist HTTP " + c2.responseCode)
            manifest = c2.inputStream.bufferedReader().use { it.readText() }
        } finally {
            c2.disconnect()
        }
        var bestUrl: String? = null
        var bestScore = if (audioOnly) Long.MAX_VALUE else -1L
        val lines = manifest.lines()
        for (i in lines.indices) {
            val l = lines[i]
            if (!l.startsWith("#EXT-X-STREAM-INF")) continue
            val url = lines.getOrNull(i + 1)?.trim().orEmpty()
            if (!url.startsWith("http")) continue
            val height = Regex("RESOLUTION=\\d+x(\\d+)").find(l)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
            val bw = Regex("BANDWIDTH=(\\d+)").find(l)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
            if (audioOnly) {
                if (bw in 1 until bestScore) { bestScore = bw; bestUrl = url }
            } else if (height in 1..maxHeight.toLong() && height > bestScore) {
                bestScore = height; bestUrl = url
            }
        }
        if (bestUrl == null && !audioOnly) {
            // nothing small enough: take the first listed
            bestUrl = lines.firstOrNull { it.startsWith("http") }?.trim()
        }
        return Triple(title, bestUrl ?: throw IOException("no stream variant"), seconds)
    }

    /** Quick way: the iOS client lists a streaming playlist (picture + sound) without downloading YouTube's player code. */
    private fun resolveFast(pageUrl: String, maxHeight: Int): Triple<String, String, Int> {
        TapCastApp.awaitReady()
        val req = com.yausername.youtubedl_android.YoutubeDLRequest(pageUrl).apply {
            addOption("--no-playlist")
            addOption("--no-warnings")
            addOption("--extractor-args", "youtube:player_client=ios;skip=dash,translated_subs")
            addOption(
                "-f",
                "best[protocol^=m3u8][height<=$maxHeight]/best[protocol^=m3u8]/best[acodec!=none][vcodec!=none][height<=$maxHeight]",
            )
            addOption("--print", "%(title)s\t%(duration)s\t%(url)s")
        }
        val out = com.yausername.youtubedl_android.YoutubeDL.getInstance().execute(req, null) { _, _, _ -> }.out
        val line = out.lineSequence().map { it.trim() }.lastOrNull { it.contains("http") }
            ?: throw IOException("Could not get a playable address for this video.")
        val parts = line.split('\t', limit = 3)
        if (parts.size < 3 || !parts[2].startsWith("http")) {
            throw IOException("Could not get a playable address for this video.")
        }
        return Triple(parts[0], parts[2], parts[1].toDoubleOrNull()?.toInt() ?: 0)
    }

    private fun resolveStream(pageUrl: String, audioOnly: Boolean, maxHeight: Int = 720): Triple<String, String, Int> {
        TapCastApp.awaitReady()
        // YouTube sometimes offers no formats to one kind of client ("Requested format is not available"):
        // try several, the first one that gives an address wins.
        val clients = listOf(null, "tv", "mweb", "web_safari", "android_vr")
        var last: Exception? = null
        for (client in clients) {
            try {
                return resolveWith(pageUrl, audioOnly, maxHeight, client)
            } catch (e: Exception) {
                last = e
            }
        }
        throw last ?: IOException("Could not get a playable address for this video.")
    }

    private fun resolveWith(pageUrl: String, audioOnly: Boolean, maxHeight: Int, client: String?): Triple<String, String, Int> {
        val req = com.yausername.youtubedl_android.YoutubeDLRequest(pageUrl).apply {
            addOption("--no-playlist")
            addOption("--no-warnings")
            if (client != null) addOption("--extractor-args", "youtube:player_client=$client")
            if (audioOnly) {
                addOption("-f", "bestaudio[ext=m4a]/bestaudio/best[acodec!=none]/best")
            } else {
                // One file with picture and sound together (TVs cannot join two streams).
                addOption(
                    "-f",
                    "best[ext=mp4][vcodec^=avc1][acodec!=none][height<=$maxHeight]/" +
                        "best[ext=mp4][acodec!=none][height<=$maxHeight]/best[ext=mp4][acodec!=none]/best[acodec!=none]/" +
                        "best[height<=$maxHeight]/best",
                )
            }
            addOption("--print", "%(title)s\t%(duration)s\t%(url)s")
        }
        val out = com.yausername.youtubedl_android.YoutubeDL.getInstance().execute(req, null) { _, _, _ -> }.out
        val line = out.lineSequence().map { it.trim() }.lastOrNull { it.contains("http") }
            ?: throw IOException("Could not get a playable address for this video.")
        val parts = line.split('\t', limit = 3)
        if (parts.size < 3 || !parts[2].startsWith("http")) {
            throw IOException("Could not get a playable address for this video.")
        }
        val seconds = parts[1].toDoubleOrNull()?.toInt() ?: 0
        return Triple(parts[0], parts[2], seconds)
    }

    private fun stopSession() {
        session?.let {
            it.cancelled = true
            it.shutdownQuietly(keepService = true)
        }
        session = null
    }

    private fun emit(map: Map<String, Any?>) {
        listener?.invoke(map)
        if (map["type"] == "cast") CastQueue.onState(map)
    }

    /** Lets other parts of the app (notification / picture-in-picture buttons) talk to Flutter. */
    fun emitExternal(map: Map<String, Any?>) = emit(map)

    // ---- discovery helpers --------------------------------------------------------

    private fun describe(location: String): Device? {
        try {
            val res = request("GET", location, emptyMap(), null)
            if (res.status !in 200..299) return null
            val xml = res.body
            val name = Regex("<friendlyName>(.*?)</friendlyName>", RegexOption.DOT_MATCHES_ALL)
                .find(xml)?.groupValues?.get(1)?.trim()?.let(::unesc) ?: "TV"
            val base = Regex("<URLBase>(.*?)</URLBase>").find(xml)?.groupValues?.get(1)?.trim()
            var avUrl: String? = null
            var avType: String? = null
            var rcUrl: String? = null
            var rcType: String? = null
            val origin = if (base.isNullOrEmpty()) location else base
            for (m in Regex("<service>(.*?)</service>", RegexOption.DOT_MATCHES_ALL).findAll(xml)) {
                val block = m.groupValues[1]
                val type = Regex("<serviceType>(.*?)</serviceType>").find(block)?.groupValues?.get(1)?.trim()
                val control = Regex("<controlURL>(.*?)</controlURL>").find(block)?.groupValues?.get(1)?.trim()
                if (type == null || control == null) continue
                val absolute = URL(URL(origin), control).toString()
                if (type.contains("AVTransport") && avUrl == null) {
                    avUrl = absolute
                    avType = type
                } else if (type.contains("RenderingControl") && rcUrl == null) {
                    rcUrl = absolute
                    rcType = type
                }
            }
            if (avUrl != null && avType != null) return Device(name, avUrl, avType, rcUrl, rcType)
        } catch (e: Exception) {
            Log.w(TAG, "could not read device description at $location", e)
        }
        return null
    }

    /** The phone's address on the network the TV is on. */
    private fun localIpFor(controlUrl: String): String {
        val u = URL(controlUrl)
        Socket().use { s ->
            s.connect(InetSocketAddress(u.host, if (u.port > 0) u.port else 80), 4000)
            return s.localAddress.hostAddress ?: throw IOException("No Wi-Fi address")
        }
    }

    // ---- minimal HTTP client over a raw socket -------------------------------------

    private class Http(val status: Int, val body: String)

    private fun request(method: String, url: String, headers: Map<String, String>, body: String?): Http {
        val u = URL(url)
        val port = if (u.port > 0) u.port else 80
        Socket().use { s ->
            s.connect(InetSocketAddress(u.host, port), 5000)
            s.soTimeout = 7000
            val bytes = body?.toByteArray(Charsets.UTF_8)
            val path = if (u.file.isNullOrEmpty()) "/" else u.file
            val head = StringBuilder()
            head.append("$method $path HTTP/1.1\r\n")
            head.append("HOST: ${u.host}:$port\r\n")
            head.append("Connection: close\r\n")
            for ((k, v) in headers) head.append("$k: $v\r\n")
            if (bytes != null) head.append("Content-Length: ${bytes.size}\r\n")
            head.append("\r\n")
            val out = s.getOutputStream()
            out.write(head.toString().toByteArray(Charsets.UTF_8))
            if (bytes != null) out.write(bytes)
            out.flush()

            val input = BufferedInputStream(s.getInputStream())
            val statusLine = readLine(input) ?: throw IOException("No answer from the device")
            val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull() ?: 0
            val responseHeaders = HashMap<String, String>()
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val i = line.indexOf(':')
                if (i > 0) responseHeaders[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
            }
            val data = when {
                responseHeaders["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true ->
                    readChunked(input)
                responseHeaders["content-length"]?.toIntOrNull() != null ->
                    readExactly(input, responseHeaders["content-length"]!!.toInt())
                else -> input.readBytes()
            }
            return Http(status, String(data, Charsets.UTF_8))
        }
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
        }
    }

    private fun readExactly(input: InputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        var read = 0
        while (read < n) {
            val r = input.read(out, read, n - read)
            if (r < 0) break
            read += r
        }
        return if (read == n) out else out.copyOf(read)
    }

    private fun readChunked(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        while (true) {
            val size = (readLine(input) ?: break).substringBefore(';').trim().toIntOrNull(16) ?: break
            if (size == 0) break
            out.write(readExactly(input, size))
            readLine(input) // CRLF after each chunk
        }
        return out.toByteArray()
    }

    private fun soapAt(url: String, type: String, action: String, args: String): String {
        val body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>" +
            "<u:$action xmlns:u=\"$type\">$args</u:$action>" +
            "</s:Body></s:Envelope>"
        val res = request(
            "POST", url,
            mapOf(
                "Content-Type" to "text/xml; charset=\"utf-8\"",
                "SOAPACTION" to "\"$type#$action\"",
            ),
            body,
        )
        if (res.status !in 200..299) throw IOException("The TV refused \"$action\" (HTTP ${res.status})")
        return res.body
    }

    /** "0:03:45" -> 225; -1 when unknown. */
    private fun parseClock(text: String?): Int {
        if (text == null) return -1
        val parts = text.trim().substringBefore('.').split(':')
        if (parts.size != 3) return -1
        val h = parts[0].toIntOrNull() ?: return -1
        val m = parts[1].toIntOrNull() ?: return -1
        val sec = parts[2].toIntOrNull() ?: return -1
        return h * 3600 + m * 60 + sec
    }

    private fun clock(totalSeconds: Int): String {
        val t = maxOf(totalSeconds, 0)
        return String.format("%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    // ---- XML helpers --------------------------------------------------------------

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&apos;")

    private fun unesc(s: String) = s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
        .replace("&apos;", "'").replace("&amp;", "&")

    private fun didl(title: String, url: String, mime: String): String {
        val isVideo = mime.startsWith("video")
        val cls = if (isVideo) "object.item.videoItem" else "object.item.audioItem.musicTrack"
        val flags = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " +
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
            "<item id=\"0\" parentID=\"-1\" restricted=\"1\">" +
            "<dc:title>${esc(title)}</dc:title>" +
            "<upnp:class>$cls</upnp:class>" +
            "<res protocolInfo=\"http-get:*:$mime:$flags\">${esc(url)}</res>" +
            "</item></DIDL-Lite>"
    }

    // ---- HTTP server that hands the files to the TV ---------------------------------

    private class MediaServer(private val resolver: ContentResolver) {
        private val files = ConcurrentHashMap<String, Pair<Uri, String>>()
        private val socket = ServerSocket(0)
        private val pool = Executors.newCachedThreadPool()

        @Volatile private var running = true

        val port: Int get() = socket.localPort

        init {
            thread(name = "dlna-http", isDaemon = true) {
                while (running) {
                    try {
                        val client = socket.accept()
                        pool.execute { handle(client) }
                    } catch (e: Exception) {
                        if (!running) break
                    }
                }
            }
        }

        fun register(uri: Uri, mime: String, ext: String): String {
            val name = "${UUID.randomUUID()}.$ext"
            files[name] = uri to mime
            return name
        }

        fun stop() {
            running = false
            try {
                socket.close()
            } catch (e: Exception) {
                // already closed
            }
            pool.shutdownNow()
        }

        private fun querySize(uri: Uri): Long = try {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else -1L
            } ?: -1L
        } catch (e: Exception) {
            -1L
        }

        private fun reply(out: BufferedOutputStream, status: String, extra: String = "") {
            out.write(("HTTP/1.1 $status\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray())
            out.flush()
        }

        private fun handle(client: Socket) {
            try {
                client.use { sock ->
                    sock.soTimeout = 30000
                    val input = BufferedInputStream(sock.getInputStream())
                    val out = BufferedOutputStream(sock.getOutputStream())
                    val requestLine = readLine(input) ?: return
                    val parts = requestLine.split(' ')
                    if (parts.size < 2) return
                    val method = parts[0]
                    val name = parts[1].substringBefore('?').removePrefix("/m/")
                    var range: String? = null
                    while (true) {
                        val line = readLine(input) ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("range:", ignoreCase = true)) range = line.substring(6).trim()
                    }
                    val entry = files[name]
                    if (entry == null) {
                        reply(out, "404 Not Found")
                        return
                    }
                    val pfd = try {
                        resolver.openFileDescriptor(entry.first, "r")
                    } catch (e: Exception) {
                        null
                    }
                    if (pfd == null) {
                        reply(out, "404 Not Found")
                        return
                    }
                    pfd.use { fd ->
                        var size = fd.statSize
                        if (size < 0) size = querySize(entry.first)
                        var start = 0L
                        var end = size - 1
                        var partial = false
                        val m = if (range != null && size > 0) Regex("bytes=(\\d*)-(\\d*)").find(range!!) else null
                        if (m != null) {
                            val a = m.groupValues[1]
                            val b = m.groupValues[2]
                            if (a.isNotEmpty()) {
                                start = a.toLong()
                                if (b.isNotEmpty()) end = minOf(b.toLong(), size - 1)
                            } else if (b.isNotEmpty()) {
                                start = maxOf(0L, size - b.toLong())
                            }
                            partial = true
                        }
                        if (size > 0 && start >= size) {
                            reply(out, "416 Range Not Satisfiable", "Content-Range: bytes */$size\r\n")
                            return
                        }
                        val length = if (size > 0) end - start + 1 else -1L
                        val head = StringBuilder()
                        head.append(if (partial) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
                        head.append("Content-Type: ${entry.second}\r\n")
                        head.append("Accept-Ranges: bytes\r\n")
                        if (length >= 0) head.append("Content-Length: $length\r\n")
                        if (partial) head.append("Content-Range: bytes $start-$end/$size\r\n")
                        head.append("transferMode.dlna.org: Streaming\r\n")
                        head.append("contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;")
                        head.append("DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n")
                        head.append("Connection: close\r\n\r\n")
                        out.write(head.toString().toByteArray())
                        if (method != "HEAD") {
                            // Not closed on purpose: closing it would close the descriptor that `pfd` owns.
                            val ins = FileInputStream(fd.fileDescriptor)
                            if (start > 0) {
                                try {
                                    ins.channel.position(start)
                                } catch (e: Exception) {
                                    var skipped = 0L
                                    while (skipped < start) {
                                        val s = ins.skip(start - skipped)
                                        if (s <= 0) break
                                        skipped += s
                                    }
                                }
                            }
                            val buf = ByteArray(64 * 1024)
                            var left = if (length >= 0) length else Long.MAX_VALUE
                            while (left > 0) {
                                val n = ins.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                                if (n < 0) break
                                out.write(buf, 0, n)
                                left -= n
                            }
                        }
                        out.flush()
                    }
                }
            } catch (e: IOException) {
                // The TV closes connections whenever it seeks or switches track.
            } catch (e: Exception) {
                Log.w(TAG, "serving a file failed", e)
            }
        }
    }

    // ---- one casting session ---------------------------------------------------------

    private class Session(
        val app: Context,
        val device: Device,
        val items: CopyOnWriteArrayList<Item>,
        val server: MediaServer,
        val ip: String,
    ) {
        @Volatile var cancelled = false
        @Volatile var index = 0
        @Volatile var status = "connecting"
        @Volatile var error: String? = null
        @Volatile var volume = -1
        @Volatile private var lastPosition = -1
        @Volatile private var lastDuration = -1
        private val liveTitles = ConcurrentHashMap<Int, String>()
        private val durations = ConcurrentHashMap<Int, Int>()

        // Some set-top boxes never report the position, so it is also tracked by the clock.
        @Volatile private var startedAt = 0L
        @Volatile private var pausedAt = 0L
        @Volatile private var pausedTotal = 0L
        @Volatile private var seekBase = 0
        @Volatile private var tvReports = false

        private class Prepared(val index: Int, val title: String, val url: String, val seconds: Int)

        @Volatile private var prepared: Prepared? = null
        @Volatile private var preparing = -1
        @Volatile private var handover = false
        @Volatile private var switchedWhilePlaying = false

        @Volatile private var jumpTo = -1
        @Volatile private var finishedUp = false

        fun toMap(): Map<String, Any?> = mapOf(
            "type" to "cast",
            "status" to status,
            "device" to device.name,
            "title" to (liveTitles[index]?.takeIf { it.isNotBlank() } ?: items.getOrNull(index)?.title),
            "uri" to items.getOrNull(index)?.uri,
            "stream" to (items.getOrNull(index)?.stream ?: false),
            "index" to index,
            "count" to items.size,
            "volume" to volume,
            "error" to error,
        )

        private fun publish(newStatus: String) {
            status = newStatus
            publishCurrent()
        }

        fun publishCurrent() {
            val map = toMap()
            emit(map)
            CastService.update(app, map)
        }

        private fun soap(action: String, args: String): String =
            soapAt(device.controlUrl, device.serviceType, action, args)

        private fun rendering(action: String, args: String): String? {
            val url = device.renderUrl ?: return null
            val type = device.renderType ?: return null
            return soapAt(url, type, action, args)
        }

        private fun readVolume() {
            try {
                val xml = rendering("GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>") ?: return
                Regex("<CurrentVolume>(\\d+)</CurrentVolume>").find(xml)?.groupValues?.get(1)?.toIntOrNull()
                    ?.let { volume = it }
            } catch (e: Exception) {
                // volume is optional
            }
        }

        private fun changeVolume(level: Int) {
            val v = level.coerceIn(0, 100)
            rendering("SetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$v</DesiredVolume>")
            volume = v
            emit(mapOf("type" to "castPos", "position" to lastPosition, "duration" to lastDuration, "volume" to volume))
        }

        private fun knownDuration(): Int = if (lastDuration > 0) lastDuration else durations[index] ?: 0

        private fun estimatedPosition(): Int {
            if (tvReports && lastPosition >= 0) return lastPosition
            if (startedAt == 0L) return 0
            val now = System.currentTimeMillis()
            val paused = pausedTotal + if (pausedAt > 0) now - pausedAt else 0L
            return maxOf(0, seekBase + ((now - startedAt - paused) / 1000).toInt())
        }

        private fun pollPosition() {
            try {
                val xml = soap("GetPositionInfo", "<InstanceID>0</InstanceID>")
                lastDuration = parseClock(Regex("<TrackDuration>(.*?)</TrackDuration>").find(xml)?.groupValues?.get(1))
                lastPosition = parseClock(Regex("<RelTime>(.*?)</RelTime>").find(xml)?.groupValues?.get(1))
                if (lastPosition > 0) tvReports = true
            } catch (e: Exception) {
                // progress is optional
            }
            val pos = estimatedPosition()
            val dur = knownDuration()
            emit(mapOf("type" to "castPos", "position" to pos, "duration" to dur, "volume" to volume))
            CastService.progress(app, pos, dur)
        }

        /** Resolves the next YouTube video ahead of time so the switch is instant. */
        private fun prefetchNext() {
            val next = index + 1
            if (next >= items.size || preparing == next || prepared?.index == next) return
            val nextItem = items[next]
            if (!nextItem.stream) return
            preparing = next // also stops retries if it fails; it is then resolved normally
            thread(name = "dlna-prefetch") {
                try {
                    val (t, u, sec) = resolveStream(nextItem.uri, nextItem.mime.startsWith("audio"))
                    prepared = Prepared(next, t, u, sec)
                } catch (e: Exception) {
                    // resolved again when it is needed
                }
            }
        }

        private fun load(url: String, title: String, mime: String) {
            soap(
                "SetAVTransportURI",
                "<InstanceID>0</InstanceID><CurrentURI>${esc(url)}</CurrentURI>" +
                    "<CurrentURIMetaData>${esc(didl(title, url, mime))}</CurrentURIMetaData>",
            )
            soap("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
        }

        private fun transportState(): String? {
            val xml = soap("GetTransportInfo", "<InstanceID>0</InstanceID>")
            return Regex("<CurrentTransportState>(.*?)</CurrentTransportState>").find(xml)?.groupValues?.get(1)
        }

        fun run() {
            try {
                while (index < items.size && !cancelled) {
                    val item = items[index]
                    lastPosition = -1
                    lastDuration = -1
                    val keepPlaying = handover
                    handover = false
                    tvReports = false
                    if (prepared?.index != index + 1) preparing = -1
                    publish("loading")
                    var title = item.title
                    val url: String
                    if (item.stream) {
                        val pre = prepared
                        val resolved: Triple<String, String, Int> = if (pre != null && pre.index == index) {
                            prepared = null
                            Triple(pre.title, pre.url, pre.seconds)
                        } else {
                            try {
                                resolveStream(item.uri, item.mime.startsWith("audio"))
                            } catch (e: Exception) {
                                // One video that cannot be played should not end the whole queue.
                                if (cancelled || index + 1 >= items.size) throw e
                                Log.w(TAG, "skipping unplayable item", e)
                                index += 1
                                continue
                            }
                        }
                        val (found, address, seconds) = resolved
                        if (found.isNotBlank()) {
                            title = found
                            liveTitles[index] = found
                        }
                        if (seconds > 0) durations[index] = seconds
                        url = address
                    } else {
                        val ext = when (item.mime) {
                            "audio/mpeg" -> "mp3"
                            "video/mp4" -> "mp4"
                            else -> item.mime.substringAfter('/', "bin")
                        }
                        val name = server.register(Uri.parse(item.uri), item.mime, ext)
                        url = "http://$ip:${server.port}/m/$name"
                    }
                    if (cancelled) break
                    if (keepPlaying) {
                        // The TV is still playing the previous video: hand over without a Stop,
                        // because some boxes leave DLNA mode ("Thanks for watching") on Stop / end.
                        try {
                            load(url, title, item.mime)
                        } catch (e: Exception) {
                            try {
                                soap("Stop", "<InstanceID>0</InstanceID>")
                            } catch (e2: Exception) {
                                // already idle
                            }
                            Thread.sleep(800)
                            load(url, title, item.mime)
                        }
                    } else {
                        try {
                            soap("Stop", "<InstanceID>0</InstanceID>")
                        } catch (e: Exception) {
                            // nothing was playing
                        }
                        load(url, title, item.mime)
                    }
                    startedAt = System.currentTimeMillis()
                    pausedAt = 0L
                    pausedTotal = 0L
                    seekBase = 0
                    publish("playing")
                    waitForEnd()
                    if (cancelled) break
                    handover = switchedWhilePlaying || jumpTo >= 0
                    switchedWhilePlaying = false
                    index = if (jumpTo >= 0) jumpTo else index + 1
                    jumpTo = -1
                }
                // "Next" on the last item (or the list ending) leaves the TV idle.
                if (!cancelled) {
                    try {
                        soap("Stop", "<InstanceID>0</InstanceID>")
                    } catch (e: Exception) {
                        // TV already stopped
                    }
                }
            } catch (e: Throwable) {
                if (!cancelled) {
                    Log.w(TAG, "cast failed", e)
                    error = e.message ?: "Casting failed"
                }
            } finally {
                finishUp()
            }
        }

        /** Returns when the current track is over (or the user skipped / stopped). */
        private fun waitForEnd() {
            var seenPlaying = false
            var atEnd = 0
            var failures = 0
            val began = System.currentTimeMillis()
            while (!cancelled && jumpTo < 0) {
                Thread.sleep(2000)
                val state = try {
                    transportState().also { failures = 0 }
                } catch (e: Exception) {
                    failures++
                    if (failures >= 5) throw IOException("Lost connection to the TV")
                    null
                }
                when (state) {
                    "PLAYING", "TRANSITIONING" -> {
                        if (!seenPlaying && volume < 0) readVolume()
                        if (!seenPlaying) {
                            // The picture really started now (not when we sent Play).
                            startedAt = System.currentTimeMillis()
                            pausedAt = 0L
                            pausedTotal = 0L
                            seekBase = 0
                        }
                        seenPlaying = true
                        if (status != "playing") publish("playing")
                        pollPosition()
                        // Some set-top boxes stay on "playing" at the very end: treat that as finished.
                        val settled = System.currentTimeMillis() - startedAt > 8000
                        if (settled && lastDuration > 5 && lastPosition >= lastDuration - 1) atEnd++ else atEnd = 0
                        if (atEnd >= 3) return
                        val dur = knownDuration()
                        if (dur > 0 && settled) {
                            val pos = estimatedPosition()
                            if (pos >= dur / 2 || dur - pos <= 60) prefetchNext()
                            // Move on a moment before the end, so the box never reaches its
                            // own "end of video" screen and the next video follows without a gap.
                            if (index + 1 < items.size && pos >= dur - 3) {
                                val nextItem = items[index + 1]
                                if (!nextItem.stream || prepared?.index == index + 1) {
                                    switchedWhilePlaying = true
                                    return
                                }
                            }
                        }
                    }
                    "PAUSED_PLAYBACK" -> {
                        if (status != "paused") publish("paused")
                        pollPosition()
                    }
                    "STOPPED", "NO_MEDIA_PRESENT" -> {
                        if (seenPlaying) return
                        if (System.currentTimeMillis() - began > 30000) {
                            throw IOException(
                                "The TV did not start playing. It may not support this file type " +
                                    "(MP4 video or MP3 audio is usually fine).",
                            )
                        }
                    }
                }
            }
        }

        fun control(action: String, value: Int) {
            try {
                when (action) {
                    "seek" -> {
                        soap("Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${clock(value)}</Target>")
                        lastPosition = value
                        seekBase = value
                        startedAt = System.currentTimeMillis()
                        pausedTotal = 0L
                        if (pausedAt > 0) pausedAt = startedAt
                        emit(mapOf("type" to "castPos", "position" to value, "duration" to knownDuration(), "volume" to volume))
                        CastService.progress(app, value, knownDuration())
                    }
                    "volume" -> changeVolume(value)
                    "volumeUp", "volumeDown" -> {
                        if (volume < 0) readVolume()
                        if (volume >= 0) changeVolume(volume + if (action == "volumeUp") 5 else -5)
                    }
                    "pause" -> {
                        soap("Pause", "<InstanceID>0</InstanceID>")
                        if (pausedAt == 0L) pausedAt = System.currentTimeMillis()
                        publish("paused")
                    }
                    "resume" -> {
                        soap("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
                        if (pausedAt > 0) {
                            pausedTotal += System.currentTimeMillis() - pausedAt
                            pausedAt = 0L
                        }
                        publish("playing")
                    }
                    "next" -> jumpTo = minOf(index + 1, items.size)
                    "previous" -> jumpTo = maxOf(index - 1, 0)
                    "stop" -> {
                        cancelled = true
                        try {
                            soap("Stop", "<InstanceID>0</InstanceID>")
                        } catch (e: Exception) {
                            // TV already gone
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "control $action failed", e)
            }
        }

        fun shutdownQuietly(keepService: Boolean = false) {
            finishUp(announce = false, keepService = keepService)
        }

        private fun finishUp(announce: Boolean = true, keepService: Boolean = false) {
            if (finishedUp) return
            finishedUp = true
            server.stop()
            // When the next video follows, the notification service stays up: Android would not
            // let a background app start a new one.
            val continuing = announce && error == null && !cancelled && CastQueue.willContinue()
            if (!keepService && !continuing) CastService.stop(app)
            if (session === this) session = null
            if (announce) {
                status = if (error != null) "error" else if (cancelled) "stopped" else "ended"
                emit(toMap())
            }
        }
    }
}
