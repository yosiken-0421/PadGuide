package com.pdguide

import android.annotation.SuppressLint
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.Executors

/** 画面読み取り＋矢印オーバーレイを常駐させる前景サービス */
class GuideService : Service() {

    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        const val ACTION_STOP = "com.pdguide.STOP"
        private const val CHANNEL = "guide"
        @Volatile var running = false
    }

    private lateinit var wm: WindowManager
    private lateinit var prefs: Prefs
    private var capturer: ScreenCapturer? = null
    private var arrowView: ArrowOverlayView? = null
    private var panel: View? = null
    private var calibration: View? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    @Volatile private var busy = false
    private var auto = false
    private var shownBoard: ByteArray? = null
    private var pendingBoard: ByteArray? = null
    private lateinit var autoButton: Button

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        if (capturer != null) return START_NOT_STICKY

        startForegroundCompat()
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33)
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        else @Suppress("DEPRECATION") intent?.getParcelableExtra(EXTRA_DATA)
        if (data == null) { stopSelf(); return START_NOT_STICKY }

        val mpm = getSystemService(MediaProjectionManager::class.java)
        val projection = mpm.getMediaProjection(code, data)
        if (projection == null) { stopSelf(); return START_NOT_STICKY }

        wm = getSystemService(WindowManager::class.java)
        prefs = Prefs(this)
        capturer = ScreenCapturer(this, projection) { main.post { stopSelf() } }
        running = true
        addArrowOverlay()
        addPanel()
        if (!prefs.calibrated) main.postDelayed({ autoDetectSilently() }, 1500)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        auto = false
        main.removeCallbacksAndMessages(null)
        listOf(arrowView, panel, calibration).forEach { v -> v?.let { try { wm.removeView(it) } catch (_: Exception) {} } }
        capturer?.release()
        capturer = null
        worker.shutdownNow()
        super.onDestroy()
    }

    // ---------- 前景サービス通知 ----------
    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "矢印ガイド", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(
            this, 1, Intent(this, GuideService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("パズドラ矢印ガイド 動作中")
            .setContentText("画面を読み取って矢印を表示しています")
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(1, n)
    }

    // ---------- オーバーレイ ----------
    private fun overlayParams(w: Int, h: Int, touchable: Boolean) = WindowManager.LayoutParams(
        w, h,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            (if (touchable) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE),
        PixelFormat.TRANSLUCENT
    ).apply {
        if (Build.VERSION.SDK_INT >= 28)
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        if (Build.VERSION.SDK_INT >= 31 && !touchable) alpha = 0.8f // Android12+: 素通しウィンドウは不透明度0.8以下が必要
    }

    private fun addArrowOverlay() {
        val v = ArrowOverlayView(this)
        wm.addView(v, overlayParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, false))
        arrowView = v
    }

    private fun btn(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        textSize = 12f
        setTextColor(Color.WHITE)
        isAllCaps = false
        minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setPadding(dp(10), dp(6), dp(10), dp(6))
        background = GradientDrawable().apply { setColor(0xCC222630.toInt()); cornerRadius = dp(8).toFloat() }
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(dp(64), LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4) }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun addPanel() {
        val lp = overlayParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, true).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(4); y = dp(120)
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(4), dp(4), dp(4), dp(6))
            background = GradientDrawable().apply { setColor(0x99000000.toInt()); cornerRadius = dp(12).toFloat() }
        }
        val handle = TextView(this).apply {
            text = "≡ 移動"
            textSize = 11f
            setTextColor(Color.LTGRAY)
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, dp(4))
        }
        var sx = 0f; var sy = 0f; var ox = 0; var oy = 0
        handle.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { sx = e.rawX; sy = e.rawY; ox = lp.x; oy = lp.y }
                MotionEvent.ACTION_MOVE -> {
                    lp.x = ox + (e.rawX - sx).toInt(); lp.y = oy + (e.rawY - sy).toInt()
                    wm.updateViewLayout(box, lp)
                }
            }
            true
        }
        box.addView(handle)
        box.addView(btn("解析") { solveOnce() })
        autoButton = btn("自動 OFF") { toggleAuto() }
        box.addView(autoButton)
        box.addView(btn("消す") { arrowView?.clear(); shownBoard = null })
        box.addView(btn("位置") { openCalibration() })
        box.addView(btn("終了") { stopSelf() })
        wm.addView(box, lp)
        panel = box
    }

    // ---------- 解析 ----------
    private fun screenRect(): RectF {
        val c = capturer!!
        return prefs.boardRect(c.width, c.height)
    }

    private fun solveOnce() {
        val c = capturer ?: return
        if (busy) return
        busy = true
        c.capture { frame ->
            if (frame == null) { busy = false; toast("画面を取得できませんでした"); return@capture }
            val rect = screenRect()
            val rd = BoardReader.read(frame, rect)
            if (!rd.looksValid) {
                busy = false
                main.post { arrowView?.showMessage(rect, "盤面を認識できません →「位置」で調整") }
                return@capture
            }
            runSolve(rd.board, rect)
        }
    }

    private fun runSolve(board: ByteArray, rect: RectF) {
        worker.execute {
            try {
                val res = Solver(prefs.maxSteps, prefs.diagonal, prefs.beamWidth).solve(board)
                main.post {
                    shownBoard = board
                    if (res.combos == 0)
                        arrowView?.showMessage(rect, "コンボが見つかりませんでした")
                    else
                        arrowView?.show(rect, res.path, "${res.combos}コンボ（最大${res.maxCombos}） / ${res.steps}手")
                }
            } finally { busy = false }
        }
    }

    private fun toggleAuto() {
        auto = !auto
        autoButton.text = if (auto) "自動 ON" else "自動 OFF"
        autoButton.background = GradientDrawable().apply {
            setColor(if (auto) 0xCC1E8E4E.toInt() else 0xCC222630.toInt()); cornerRadius = dp(8).toFloat()
        }
        if (auto) autoTick()
    }

    /** 自動モード：盤面が変化して落ち着いたら（2回連続で同じなら）再計算 */
    private fun autoTick() {
        if (!auto) return
        val c = capturer ?: return
        if (!busy && calibration == null) {
            busy = true
            c.capture { frame ->
                if (frame == null) { busy = false; return@capture }
                val rect = screenRect()
                val rd = BoardReader.read(frame, rect)
                if (!rd.looksValid) {
                    pendingBoard = null
                    busy = false
                    if (shownBoard != null) main.post { arrowView?.clear(); shownBoard = null }
                    return@capture
                }
                val b = rd.board
                val shown = shownBoard
                if (shown != null && shown.contentEquals(b)) { busy = false; return@capture }
                val pend = pendingBoard
                if (pend != null && pend.contentEquals(b)) {
                    pendingBoard = null
                    runSolve(b, rect)
                } else {
                    pendingBoard = b
                    busy = false
                }
            }
        }
        main.postDelayed({ autoTick() }, 450)
    }

    // ---------- 位置調整 ----------
    private fun autoDetectSilently() {
        capturer?.capture { f ->
            val r = f?.let { BoardReader.autoDetect(it) } ?: return@capture
            main.post { prefs.saveRect(r, capturer!!.width, capturer!!.height) }
        }
    }

    private fun openCalibration() {
        if (calibration != null) return
        val c = capturer ?: return
        arrowView?.clear()
        // 矢印を消してから最新画面を取り込む
        main.postDelayed({
            c.capture { frame -> main.post { showCalibration(frame) } }
        }, 150)
    }

    private fun showCalibration(frame: Frame?) {
        val c = capturer ?: return
        val view = CalibrationView(this, screenRect(), frame)
        val root = FrameLayout(this)
        root.addView(view, FrameLayout.LayoutParams(-1, -1))
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        fun barBtn(t: String, f: () -> Unit) = btn(t, f).apply {
            layoutParams = LinearLayout.LayoutParams(dp(96), LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), 0, dp(4), 0) }
            textSize = 14f
        }
        bar.addView(barBtn("自動検出") {
            val r = frame?.let { BoardReader.autoDetect(it) }
            if (r != null) view.setRect(r) else toast("自動検出できませんでした。手動で合わせてください")
        })
        bar.addView(barBtn("キャンセル") { closeCalibration() })
        bar.addView(barBtn("決定") {
            prefs.saveRect(view.rect, c.width, c.height)
            closeCalibration()
            shownBoard = null
        })
        root.addView(bar, FrameLayout.LayoutParams(-1, -2, Gravity.TOP).apply { topMargin = dp(48) })
        wm.addView(root, overlayParams(-1, -1, true))
        calibration = root
        panel?.visibility = View.GONE
    }

    private fun closeCalibration() {
        calibration?.let { wm.removeView(it) }
        calibration = null
        panel?.visibility = View.VISIBLE
    }

    private fun toast(s: String) = main.post { Toast.makeText(this, s, Toast.LENGTH_SHORT).show() }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
