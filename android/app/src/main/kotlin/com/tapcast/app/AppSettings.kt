package com.tapcast.app

import android.content.Context
import android.content.SharedPreferences

/**
 * Read-only view of the settings the Flutter side saves. Flutter's
 * shared_preferences plugin writes into the `FlutterSharedPreferences` file with
 * every key prefixed by `flutter.` (ints are stored as Long, so they are read
 * through Number).
 */
object AppSettings {

    private fun prefs(c: Context): SharedPreferences =
        c.applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    private fun raw(c: Context, key: String): Any? = prefs(c).all["flutter.$key"]

    private fun string(c: Context, key: String, def: String?): String? = (raw(c, key) as? String) ?: def
    private fun bool(c: Context, key: String, def: Boolean): Boolean = (raw(c, key) as? Boolean) ?: def
    private fun int(c: Context, key: String, def: Int): Int = (raw(c, key) as? Number)?.toInt() ?: def

    /** original | clean | short */
    fun nameStyle(c: Context): String = string(c, "name_style", "clean") ?: "clean"

    fun coverArt(c: Context): Boolean = bool(c, "cover_art", true)
    fun playlistFolders(c: Context): Boolean = bool(c, "playlist_folders", true)
    fun wifiOnly(c: Context): Boolean = bool(c, "wifi_only", false)
    fun autoUpdate(c: Context): Boolean = bool(c, "auto_update", true)
    fun parallel(c: Context): Int = int(c, "parallel", 2).coerceIn(1, 4)

    /** system | light | dark */
    fun themeMode(c: Context): String = string(c, "theme_mode", "system") ?: "system"

    /** The TV used last time (saved by the Flutter side and by the share pop-up). */
    fun lastDevice(c: Context): DlnaCaster.Device? {
        val text = string(c, "last_device", null) ?: return null
        return try {
            val j = org.json.JSONObject(text)
            DlnaCaster.Device(
                j.optString("name", "TV"),
                j.getString("controlUrl"),
                j.getString("serviceType"),
                j.optString("renderUrl").takeIf { it.isNotEmpty() && it != "null" },
                j.optString("renderType").takeIf { it.isNotEmpty() && it != "null" },
            )
        } catch (e: Exception) {
            null
        }
    }

    fun saveDevice(c: Context, d: DlnaCaster.Device) {
        val j = org.json.JSONObject(d.toMap())
        prefs(c).edit().putString("flutter.last_device", j.toString()).apply()
    }
}
