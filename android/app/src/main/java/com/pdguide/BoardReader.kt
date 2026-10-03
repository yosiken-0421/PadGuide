package com.pdguide

import android.graphics.Color
import android.graphics.RectF

/**
 * 画面フレームから 6×5 の盤面を読み取る。
 * 各マスの中心は矢印表示で隠れるため、中心から斜めにずらした4点をサンプリングして多数決する。
 * （矢印は白黒で描くので、重なった点は「?」扱いになり多数決から外れる）
 */
object BoardReader {

    class Reading(val board: ByteArray, val confidence: Float) {
        val unknownCount get() = board.count { it == Orb.OTHER }
        /** パズル画面らしいか（メニュー画面などを弾く） */
        val looksValid get() = confidence >= 0.55f && unknownCount <= 8
    }

    private val SAMPLE_POINTS = arrayOf(
        floatArrayOf(0.30f, 0.30f), floatArrayOf(0.70f, 0.30f),
        floatArrayOf(0.30f, 0.70f), floatArrayOf(0.70f, 0.70f),
    )

    fun read(f: Frame, rect: RectF): Reading {
        val cell = rect.width() / Orb.COLS
        val radius = maxOf(1, (cell * 0.05f).toInt())
        val board = ByteArray(Orb.CELLS)
        var agree = 0f
        val votes = IntArray(7)
        for (r in 0 until Orb.ROWS) for (c in 0 until Orb.COLS) {
            votes.fill(0)
            for (p in SAMPLE_POINTS) {
                val x = (rect.left + (c + p[0]) * cell).toInt()
                val y = (rect.top + (r + p[1]) * cell).toInt()
                votes[classify(avg(f, x, y, radius)).toInt()]++
            }
            var bestColor = -1
            for (k in 0..5) if (votes[k] > 0 && (bestColor < 0 || votes[k] > votes[bestColor])) bestColor = k
            board[r * Orb.COLS + c] = if (bestColor >= 0) bestColor.toByte() else Orb.OTHER
            agree += (if (bestColor >= 0) votes[bestColor] else votes[6]) / 4f
        }
        return Reading(board, agree / Orb.CELLS)
    }

    /** 盤面の上下位置を自動検出（幅は画面幅いっぱいと仮定）。見つからなければ null */
    fun autoDetect(f: Frame): RectF? {
        val w = f.width.toFloat()
        val cell = w / Orb.COLS
        val h = cell * Orb.ROWS
        var bestY = -1f
        var bestScore = -1e9f
        var y = f.height * 0.3f
        val step = maxOf(2f, cell / 40f)
        while (y + h <= f.height) {
            val s = orbScore(f, 0f, y, cell)
            if (s > bestScore) { bestScore = s; bestY = y }
            y += step
        }
        if (bestY < 0) return null
        val rect = RectF(0f, bestY, w, bestY + h)
        return if (read(f, rect).looksValid) rect else null
    }

    /** ドロップらしさ：中心付近が鮮やか＆四隅（盤の地）が暗いほど高い */
    private fun orbScore(f: Frame, left: Float, top: Float, cell: Float): Float {
        var s = 0f
        val hsv = FloatArray(3)
        for (r in 0 until Orb.ROWS) for (c in 0 until Orb.COLS) {
            val x0 = left + c * cell
            val y0 = top + r * cell
            Color.colorToHSV(f.get((x0 + cell * 0.3f).toInt(), (y0 + cell * 0.3f).toInt()), hsv)
            val s1 = hsv[1] * hsv[2]
            Color.colorToHSV(f.get((x0 + cell * 0.7f).toInt(), (y0 + cell * 0.7f).toInt()), hsv)
            val s2 = hsv[1] * hsv[2]
            Color.colorToHSV(f.get((x0 + cell * 0.04f).toInt(), (y0 + cell * 0.04f).toInt()), hsv)
            val corner = hsv[2]
            s += (s1 + s2) - corner * 0.8f
        }
        return s
    }

    private fun avg(f: Frame, cx: Int, cy: Int, r: Int): Int {
        var rs = 0L; var gs = 0L; var bs = 0L; var n = 0
        val st = maxOf(1, r / 3)
        var y = cy - r
        while (y <= cy + r) {
            var x = cx - r
            while (x <= cx + r) {
                val p = f.get(x, y)
                rs += (p shr 16) and 0xFF; gs += (p shr 8) and 0xFF; bs += p and 0xFF; n++
                x += st
            }
            y += st
        }
        return Color.rgb((rs / n).toInt(), (gs / n).toInt(), (bs / n).toInt())
    }

    fun classify(argb: Int): Byte {
        val hsv = FloatArray(3)
        Color.colorToHSV(argb, hsv)
        val h = hsv[0]; val s = hsv[1]; val v = hsv[2]
        if (s < 0.28f || v < 0.25f) return Orb.OTHER
        return when {
            h >= 345f || h < 30f -> Orb.FIRE
            h < 72f -> Orb.LIGHT
            h < 165f -> Orb.WOOD
            h < 250f -> Orb.WATER
            h < 300f -> Orb.DARK
            else -> Orb.HEART // 300〜345 ピンク
        }
    }
}
