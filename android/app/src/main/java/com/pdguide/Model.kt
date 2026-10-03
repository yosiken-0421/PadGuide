package com.pdguide

import android.content.Context
import android.graphics.RectF

/** ドロップ種別。OTHER はお邪魔・毒・不明など（消えない扱い） */
object Orb {
    const val FIRE: Byte = 0
    const val WATER: Byte = 1
    const val WOOD: Byte = 2
    const val LIGHT: Byte = 3
    const val DARK: Byte = 4
    const val HEART: Byte = 5
    const val OTHER: Byte = 6
    const val EMPTY: Byte = -1

    const val ROWS = 5
    const val COLS = 6
    const val CELLS = ROWS * COLS

    val COLORS = intArrayOf(
        0xFFFF4A3A.toInt(), // 火
        0xFF3AA0FF.toInt(), // 水
        0xFF3ACF5A.toInt(), // 木
        0xFFFFE04A.toInt(), // 光
        0xFFB45AE6.toInt(), // 闇
        0xFFFF8AC8.toInt(), // 回復
        0xFF8A8A8A.toInt(), // その他
    )
    val LABELS = arrayOf("火", "水", "木", "光", "闇", "回", "?")
}

/** キャプチャした1フレーム（ARGB） */
class Frame(val width: Int, val height: Int, val pixels: IntArray) {
    fun get(x: Int, y: Int): Int {
        val cx = x.coerceIn(0, width - 1)
        val cy = y.coerceIn(0, height - 1)
        return pixels[cy * width + cx]
    }
}

class Prefs(ctx: Context) {
    private val sp = ctx.getSharedPreferences("pdguide", Context.MODE_PRIVATE)

    /** 盤面の位置（画面サイズに対する割合）。高さは幅×5/6 で決まる */
    var boardLeft: Float
        get() = sp.getFloat("bl", 0f)
        set(v) = sp.edit().putFloat("bl", v).apply()
    var boardTop: Float
        get() = sp.getFloat("bt", 0.52f)
        set(v) = sp.edit().putFloat("bt", v).apply()
    var boardWidth: Float
        get() = sp.getFloat("bw", 1f)
        set(v) = sp.edit().putFloat("bw", v).apply()
    var calibrated: Boolean
        get() = sp.getBoolean("cal", false)
        set(v) = sp.edit().putBoolean("cal", v).apply()

    var maxSteps: Int
        get() = sp.getInt("steps", 20)
        set(v) = sp.edit().putInt("steps", v).apply()
    var diagonal: Boolean
        get() = sp.getBoolean("diag", false)
        set(v) = sp.edit().putBoolean("diag", v).apply()
    var beamWidth: Int
        get() = sp.getInt("beam", 1200)
        set(v) = sp.edit().putInt("beam", v).apply()

    fun boardRect(screenW: Int, screenH: Int): RectF {
        val l = boardLeft * screenW
        val t = boardTop * screenH
        val w = boardWidth * screenW
        return RectF(l, t, l + w, t + w * Orb.ROWS / Orb.COLS)
    }

    fun saveRect(r: RectF, screenW: Int, screenH: Int) {
        boardLeft = r.left / screenW
        boardTop = r.top / screenH
        boardWidth = r.width() / screenW
        calibrated = true
    }
}
