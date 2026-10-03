package com.pdguide

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.DisplayMetrics
import android.view.WindowManager

/** MediaProjection で画面をリアルタイムに取り込み、要求時に最新フレームを返す */
class ScreenCapturer(ctx: Context, private val projection: MediaProjection, onStopped: () -> Unit) {

    val width: Int
    val height: Int
    private val density: Int
    private val thread = HandlerThread("capture").apply { start() }
    private val handler = Handler(thread.looper)
    private val reader: ImageReader
    private var display: VirtualDisplay? = null
    private var held: Image? = null
    private var bitmap: Bitmap? = null

    init {
        val wm = ctx.getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds
            width = b.width(); height = b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            width = m.widthPixels; height = m.heightPixels
        }
        density = ctx.resources.displayMetrics.densityDpi

        reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { onStopped() }
        }, handler)
        display = projection.createVirtualDisplay(
            "pdguide", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, handler
        )
        // 画面が変化するたびに最新フレームを1枚だけ保持しておく（静止画面でも取得できるように）
        reader.setOnImageAvailableListener({ r ->
            val img = try { r.acquireLatestImage() } catch (e: Exception) { null } ?: return@setOnImageAvailableListener
            held?.close()
            held = img
        }, handler)
    }

    /** 最新フレームを取得（コールバックはキャプチャ用スレッドで呼ばれる） */
    fun capture(callback: (Frame?) -> Unit) {
        handler.post {
            val img = held
            if (img == null) { callback(null); return@post }
            try {
                val plane = img.planes[0]
                val rowPixels = plane.rowStride / plane.pixelStride
                var bmp = bitmap
                if (bmp == null || bmp.width != rowPixels || bmp.height != img.height) {
                    bmp?.recycle()
                    bmp = Bitmap.createBitmap(rowPixels, img.height, Bitmap.Config.ARGB_8888)
                    bitmap = bmp
                }
                val buf = plane.buffer
                buf.rewind()
                bmp!!.copyPixelsFromBuffer(buf)
                val w = minOf(img.width, rowPixels)
                val px = IntArray(w * img.height)
                bmp.getPixels(px, 0, w, 0, 0, w, img.height)
                callback(Frame(w, img.height, px))
            } catch (e: Exception) {
                callback(null)
            }
        }
    }

    fun release() {
        handler.post {
            held?.close(); held = null
            display?.release(); display = null
            reader.close()
            bitmap?.recycle(); bitmap = null
            try { projection.stop() } catch (_: Exception) {}
            thread.quitSafely()
        }
    }
}
