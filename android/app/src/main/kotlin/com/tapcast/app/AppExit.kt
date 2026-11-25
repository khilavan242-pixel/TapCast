package com.tapcast.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlin.concurrent.thread

/** TapCast only lives while it is casting: these end it completely. */
object AppExit {

    /** Stops the TV, closes the screen and ends the process (the X button, the stop button). */
    fun closeAll(context: Context) {
        val app = context.applicationContext
        thread(name = "app-exit") {
            try {
                DlnaCaster.stopNow()
            } catch (e: Exception) {
                // the TV may already be gone
            }
            Handler(Looper.getMainLooper()).post {
                CastService.stop(app)
                MainActivity.current?.finishAndRemoveTask()
                Handler(Looper.getMainLooper()).postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 400)
            }
        }
    }

    /** Swiped away from recent apps: stop the TV and leave. */
    fun swipedAway(context: Context) {
        val app = context.applicationContext
        thread(name = "app-exit") {
            try {
                DlnaCaster.stopNow()
            } catch (e: Exception) {
                // ignore
            }
            Handler(Looper.getMainLooper()).post {
                CastService.stop(app)
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    /** Nothing has played for a while: release everything; close the process if the screen is not in use. */
    fun idle(context: Context) {
        val app = context.applicationContext
        if (MainActivity.visible) {
            CastService.stop(app)
            return
        }
        closeAll(app)
    }
}
