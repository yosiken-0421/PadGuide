package com.pdguide

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * 画面全体に重ねる透明ビュー。盤面上に操作経路の矢印を描く（タッチは下のゲームに素通し）。
 * 盤面読み取りを邪魔しないよう、線は白＋黒縁（彩度なし）で描く。
 */
class ArrowOverlayView(ctx: Context) : View(ctx) {

    private var rect: RectF? = null
    private var path: IntArray? = null
    private var label: String = ""
    private var message: String? = null
    private val screenLoc = IntArray(2)

    private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6000000.toInt(); style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
        setShadowLayer(6f, 0f, 0f, Color.BLACK)
    }

    private var progress = 0f
    private val animator = ValueAnimator.ofFloat(0f, 1f).apply {
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { progress = it.animatedValue as Float; invalidate() }
    }

    fun show(boardRect: RectF, p: IntArray, info: String) {
        rect = boardRect; path = p; label = info; message = null
        animator.duration = (600L + p.size * 220L)
        if (!animator.isStarted) animator.start()
        invalidate()
    }

    fun showMessage(boardRect: RectF?, msg: String) {
        rect = boardRect; path = null; message = msg
        animator.cancel(); invalidate()
    }

    fun clear() {
        path = null; message = null; animator.cancel(); invalidate()
    }

    override fun onDetachedFromWindow() { animator.cancel(); super.onDetachedFromWindow() }

    override fun onDraw(canvas: Canvas) {
        val r = rect ?: return
        getLocationOnScreen(screenLoc)
        canvas.save()
        canvas.translate(-screenLoc[0].toFloat(), -screenLoc[1].toFloat())
        val cell = r.width() / Orb.COLS
        text.textSize = cell * 0.32f

        message?.let {
            canvas.drawText(it, r.centerX(), r.top - cell * 0.25f, text)
        }
        val p = path
        if (p != null && p.isNotEmpty()) {
            val pts = PathGeometry.points(p, r)
            outline.strokeWidth = cell * 0.17f
            line.strokeWidth = cell * 0.10f
            val head = cell * 0.22f

            // 線本体
            val gp = Path()
            gp.moveTo(pts[0].x, pts[0].y)
            for (i in 1 until pts.size) gp.lineTo(pts[i].x, pts[i].y)
            canvas.drawPath(gp, outline)
            canvas.drawPath(gp, line)
            // 各区間の矢じり
            for (i in 1 until pts.size) drawHead(canvas, pts[i - 1], pts[i], head)

            // 開始：緑の輪、終了：赤い四角
            fill.style = Paint.Style.STROKE
            fill.strokeWidth = cell * 0.07f
            fill.color = 0xFF2BE36B.toInt()
            canvas.drawCircle(pts[0].x, pts[0].y, cell * 0.18f, fill)
            fill.style = Paint.Style.FILL
            fill.color = 0xFFFF3B3B.toInt()
            val e = pts.last()
            val hs = cell * 0.1f
            canvas.drawRect(e.x - hs, e.y - hs, e.x + hs, e.y + hs, fill)

            // 経路をなぞって動く光点（順番がわかるように）
            val dot = PathGeometry.pointAt(pts, progress)
            fill.color = Color.WHITE
            canvas.drawCircle(dot.x, dot.y, cell * 0.11f, outline)
            canvas.drawCircle(dot.x, dot.y, cell * 0.09f, fill)

            canvas.drawText(label, r.centerX(), r.top - cell * 0.25f, text)
        }
        canvas.restore()
    }

    private fun drawHead(c: Canvas, a: PointF, b: PointF, size: Float) {
        val ang = atan2((b.y - a.y).toDouble(), (b.x - a.x).toDouble())
        // 区間の 70% 地点に矢じり
        val tx = a.x + (b.x - a.x) * 0.7f
        val ty = a.y + (b.y - a.y) * 0.7f
        val p = Path()
        p.moveTo(tx + (size * cos(ang)).toFloat(), ty + (size * sin(ang)).toFloat())
        p.lineTo(tx + (size * 0.8 * cos(ang + 2.4)).toFloat(), ty + (size * 0.8 * sin(ang + 2.4)).toFloat())
        p.lineTo(tx + (size * 0.8 * cos(ang - 2.4)).toFloat(), ty + (size * 0.8 * sin(ang - 2.4)).toFloat())
        p.close()
        fill.style = Paint.Style.FILL
        fill.color = Color.WHITE
        outline.strokeWidth = size * 0.25f
        c.drawPath(p, outline)
        c.drawPath(p, fill)
        outline.strokeWidth = size / 0.22f * 0.17f
    }
}

/** 経路の座標計算。同じ区間を往復する場合は少しずらして重ならないようにする */
object PathGeometry {
    fun points(path: IntArray, r: RectF): List<PointF> {
        val cell = r.width() / Orb.COLS
        val used = HashMap<Int, Int>()
        val res = ArrayList<PointF>()
        for ((i, idx) in path.withIndex()) {
            val cx = r.left + (idx % Orb.COLS + 0.5f) * cell
            val cy = r.top + (idx / Orb.COLS + 0.5f) * cell
            // 同じマスを何度も通るときは少しずつ位置をずらす
            val n = used.getOrDefault(idx, 0)
            used[idx] = n + 1
            val off = if (i == 0) 0f else n * cell * 0.09f
            res.add(PointF(cx + off, cy + off))
        }
        return res
    }

    fun pointAt(pts: List<PointF>, t: Float): PointF {
        if (pts.size < 2) return pts[0]
        val lens = FloatArray(pts.size - 1) { hypot(pts[it + 1].x - pts[it].x, pts[it + 1].y - pts[it].y) }
        var target = lens.sum() * t
        for (i in lens.indices) {
            if (target <= lens[i] || i == lens.lastIndex) {
                val k = if (lens[i] == 0f) 0f else (target / lens[i]).coerceIn(0f, 1f)
                return PointF(pts[i].x + (pts[i + 1].x - pts[i].x) * k, pts[i].y + (pts[i + 1].y - pts[i].y) * k)
            }
            target -= lens[i]
        }
        return pts.last()
    }
}
