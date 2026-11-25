package com.tapcast.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Size

/** Picture for a file on the phone: its thumbnail, album art, or a video frame. Call off the main thread. */
object MediaThumbs {
    fun load(context: Context, uriText: String): Bitmap? {
        val uri = Uri.parse(uriText)
        try {
            return context.contentResolver.loadThumbnail(uri, Size(512, 512), null)
        } catch (e: Exception) {
            // not supported for this provider, try the file itself
        }
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val art = retriever.embeddedPicture
            if (art != null) {
                BitmapFactory.decodeByteArray(art, 0, art.size)
            } else {
                retriever.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
        } catch (e: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // already released
            }
        }
    }
}
