package com.pdguide

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.view.MotionEvent
import android.view.View

/**
 * 盤面位置の調整画面。枠をドラッグで移動、右下の丸をドラッグで拡大縮小（6:5固定）。
 * 直前に取り込んだ画面を使って、各マスの認識結果を色付きの点でリアルタイム表示する。
 */
@SuppressLint("ViewConstructor")
class CalibrationView(
    ctx: Context,
    initial: RectF,
    private val frame: Frame?,
) : View(ctx) {

    val rect = RectF(initial)
    private val loc = IntArray(2)
    private var mode = 0 // 0:なし 1:移動 2:拡縮
    private var lastX = 0f
    private var lastY = 0f
    private var reading: BoardReader.Reading? = null

    private val dim = Paint().apply { color = 0x66000000 }
    private val frameP = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF00E5FF.toInt(); style = Paint.Style.STROKE; strokeWidth = 5f }
    private val grid = Paint().apply { color = 0x9900E5FF.toInt(); strokeWidth = 2f }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    private val txt = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
        setShadowLayer(5f, 0f, 0f, Color.BLACK)
    }

    init { reread() }

    fun setRect(r: RectF) { rect.set(r); reread(); invalidate() }

    private fun reread() { reading = frame?.let { BoardReader.read(it, rect) } }

    override fun onDraw(c: Canvas) {
        getLocationOnScreen(loc)
        c.save()
        c.translate(-loc[0].toFloat(), -loc[1].toFloat())
        val sw = (width + loc[0]).toFloat(); val sh = (height + loc[1]).toFloat()
        // 枠の外を暗く
        c.drawRect(0f, 0f, sw, rect.top, dim)
        c.drawRect(0f, rect.bottom, sw, sh, dim)
        c.drawRect(0f, rect.top, rect.left, rect.bottom, dim)
        c.drawRect(rect.right, rect.top, sw, rect.bottom, dim)

        val cell = rect.width() / Orb.COLS
        for (i in 1 until Orb.COLS) c.drawLine(rect.left + i * cell, rect.top, rect.left + i * cell, rect.bottom, grid)
        for (i in 1 until Orb.ROWS) c.drawLine(rect.left, rect.top + i * cell, rect.right, rect.top + i * cell, grid)
        c.drawRect(rect, frameP)

        txt.textSize = cell * 0.26f
        reading?.let { rd ->
            for (i in 0 until Orb.CELLS) {
                val cx = rect.left + (i % Orb.COLS + 0.5f) * cell
                val cy = rect.top + (i / Orb.COLS + 0.5f) * cell
                dot.color = Orb.COLORS[rd.board[i].toInt()]
                c.drawCircle(cx, cy, cell * 0.16f, dot)
                c.drawText(Orb.LABELS[rd.board[i].toInt()], cx, cy + cell * 0.09f, txt)
            }
            val ok = if (rd.looksValid) "認識OK" else "認識できていません"
            c.drawText("$ok（信頼度 ${(rd.confidence * 100).toInt()}%）", rect.centerX(), rect.top - cell * 0.3f, txt)
        }
        // 拡縮ハンドル
        dot.color = 0xFF00E5FF.toInt()
        c.drawCircle(rect.right, rect.bottom, cell * 0.18f, dot)
        c.drawText("枠を指で動かして盤面に合わせてください", rect.centerX(), rect.top - cell * 0.75f, txt)
        c.restore()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        val x = e.rawX; val y = e.rawY
        val cell = rect.width() / Orb.COLS
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = if (hypot(x - rect.right, y - rect.bottom) < cell * 0.7f) 2 else 1
                lastX = x; lastY = y
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = x - lastX; val dy = y - lastY
                if (mode == 1) rect.offset(dx, dy)
                else if (mode == 2) {
                    val nw = (rect.width() + dx).coerceAtLeast(200f)
                    rect.right = rect.left + nw
                    rect.bottom = rect.top + nw * Orb.ROWS / Orb.COLS
                }
                lastX = x; lastY = y
                reread(); invalidate()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> mode = 0
        }
        return true
    }

    private fun hypot(a: Float, b: Float) = kotlin.math.hypot(a, b)
}
