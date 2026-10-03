package com.pdguide

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.*

class MainActivity : Activity() {

    private val REQ_CAPTURE = 10
    private lateinit var prefs: Prefs
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
        }
        fun title(t: String, size: Float = 16f) = TextView(this).apply {
            text = t; textSize = size; setPadding(0, pad, 0, pad / 3)
        }
        root.addView(title("パズルルート", 24f))
        status = title("", 14f)
        root.addView(status)

        root.addView(Button(this).apply {
            text = "① 他のアプリの上に表示を許可"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
            }
        })

        // 設定
        val stepsLabel = title("")
        val steps = SeekBar(this).apply {
            max = 40 - 8
            progress = prefs.maxSteps - 8
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(s: SeekBar?, p: Int, u: Boolean) {
                    prefs.maxSteps = p + 8; stepsLabel.text = "最大手数：${p + 8}手"
                }
                override fun onStartTrackingTouch(s: SeekBar?) {}
                override fun onStopTrackingTouch(s: SeekBar?) {}
            })
        }
        stepsLabel.text = "最大手数：${prefs.maxSteps}手"
        root.addView(stepsLabel); root.addView(steps)

        root.addView(Switch(this).apply {
            text = "斜め移動を使う"
            isChecked = prefs.diagonal
            setOnCheckedChangeListener { _, b -> prefs.diagonal = b }
        })

        val beamLabel = title("")
        val levels = intArrayOf(300, 800, 1200, 2500, 5000)
        val names = arrayOf("速い", "やや速い", "標準", "高精度", "最高精度（重い）")
        val beam = SeekBar(this).apply {
            max = levels.size - 1
            progress = levels.indexOfFirst { it >= prefs.beamWidth }.let { if (it < 0) 2 else it }
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(s: SeekBar?, p: Int, u: Boolean) {
                    prefs.beamWidth = levels[p]; beamLabel.text = "探索精度：${names[p]}"
                }
                override fun onStartTrackingTouch(s: SeekBar?) {}
                override fun onStopTrackingTouch(s: SeekBar?) {}
            })
        }
        beamLabel.text = "探索精度：${names[beam.progress]}"
        root.addView(beamLabel); root.addView(beam)

        root.addView(Button(this).apply {
            text = "② ガイド開始（画面の読み取りを許可）"
            setBackgroundColor(0xFF1E8E4E.toInt()); setTextColor(Color.WHITE)
            setOnClickListener { start() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = pad })

        root.addView(Button(this).apply {
            text = "ガイド停止"
            setOnClickListener { stopService(Intent(this@MainActivity, GuideService::class.java)); refresh() }
        })

        root.addView(TextView(this).apply {
            textSize = 13f
            setPadding(0, pad, 0, 0)
            text = """
                使い方
                ・開始時の確認画面では「画面全体」を共有を選んでください
                ・パズドラが開いたら、浮いているボタンの「解析」で矢印が出ます
                ・「自動 ON」にすると盤面が変わるたびに自動で矢印を更新します
                ・初回や矢印がずれる時は「位置」で枠を盤面に合わせてください
                ・緑の輪＝つかむドロップ、赤い四角＝離す位置、動く白い点＝なぞる順番
            """.trimIndent()
        })

        setContentView(ScrollView(this).apply { addView(root) })
    }

    override fun onResume() { super.onResume(); refresh() }

    private fun refresh() {
        val overlay = Settings.canDrawOverlays(this)
        status.text = buildString {
            append(if (overlay) "✓ 重ねて表示：許可済み\n" else "✗ 重ねて表示：未許可（①を押してください）\n")
            append(if (GuideService.running) "● ガイド動作中" else "○ ガイド停止中")
        }
    }

    private fun start() {
        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "先に①の許可をしてください", Toast.LENGTH_LONG).show(); return
        }
        if (GuideService.running) { launchPad(); return }
        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_CAPTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CAPTURE) return
        if (resultCode != RESULT_OK || data == null) {
            Toast.makeText(this, "画面の読み取りが許可されませんでした", Toast.LENGTH_SHORT).show(); return
        }
        val i = Intent(this, GuideService::class.java)
            .putExtra(GuideService.EXTRA_CODE, resultCode)
            .putExtra(GuideService.EXTRA_DATA, data)
        startForegroundService(i)
        launchPad()
    }

    private fun launchPad() {
        for (pkg in listOf("jp.gungho.pad", "jp.gungho.padEN")) {
            val i = packageManager.getLaunchIntentForPackage(pkg)
            if (i != null) { startActivity(i); return }
        }
        moveTaskToBack(true)
    }
}
