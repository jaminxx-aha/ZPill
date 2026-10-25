package com.jaminxx.nikonpill.video

import android.app.Activity
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import kotlin.math.roundToInt

/**
 * 全屏视频播放(NikonPill Android,`nikonpill/video` play 的宿主)。
 *
 * 对应 iOS VideoPlugin.swift 的 AVKit 全屏路径:黑底全屏 + 左上关闭钮
 * (点击 = finish → VideoPlugin 交付通道 result),播完自然收口。
 * MediaPlayer + TextureView(零新依赖;ExoPlayer 档留待需要字幕/流式
 * 时再引 media3):
 * - [rate] ≠ 1(顺帧预览)→ 静音(setPlaybackParams 变速 + setVolume 0
 *  —— 变速下音轨无意义,OpenZCine conform 同款;iOS 同语义);
 * - 画面按视频宽高比 letterbox(黑底全屏,居中收进,不裁切不拉伸);
 * - 旋转不重建(configChanges 全量),Activity 自身就是全屏画面。
 *
 * 生命周期:VideoPlugin 持有待交付的 MethodChannel.Result,本页
 * finish(onDestroy)即回调 —— 异常退出(系统回收)也如实交付。
 */
class VideoActivity : Activity() {
    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_RATE = "rate"
    }

    private var player: MediaPlayer? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var textureView: TextureView? = null
    private var videoFrame: FrameLayout? = null
    private var pendingSurface: Surface? = null

    private val surfaceListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(
            surface: SurfaceTexture,
            width: Int,
            height: Int,
        ) {
            startPlayer(Surface(surface))
        }

        override fun onSurfaceTextureSizeChanged(
            surface: SurfaceTexture,
            width: Int,
            height: Int,
        ) {
            layoutVideoFrame(width, height)
        }

        override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
            player?.setSurface(null)
            return true
        }

        override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )

        val root = FrameLayout(this).apply { setBackgroundColor(0xFF000000.toInt()) }

        videoFrame = FrameLayout(this).also { root.addView(it) }
        textureView = TextureView(this).apply {
            surfaceTextureListener = surfaceListener
            videoFrame!!.addView(
                this,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER,
                ),
            )
        }

        // 左上关闭钮(iOS AVKit 路径同位同语义)
        val close = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setPadding(32, 32, 32, 32)
            contentDescription = "关闭"
            setOnClickListener { finish() }
        }
        root.addView(
            close,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.START,
            ),
        )
        setContentView(root)
    }

    private fun startPlayer(surface: Surface) {
        val path = intent.getStringExtra(EXTRA_PATH) ?: run {
            finish()
            return
        }
        val rate = intent.getDoubleExtra(EXTRA_RATE, 1.0)
        pendingSurface = surface
        val p = MediaPlayer()
        player = p
        try {
            p.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            p.setDataSource(path)
            p.setSurface(surface)
            p.setOnVideoSizeChangedListener { _, w, h ->
                videoWidth = w
                videoHeight = h
                textureView?.let { layoutVideoFrame(it.width, it.height) }
            }
            p.setOnPreparedListener { mp ->
                if (rate != 1.0) {
                    mp.setVolume(0f, 0f) // 顺帧变速静音(音轨无意义)
                    mp.playbackParams = mp.playbackParams.setSpeed(rate.toFloat())
                    // setPlaybackParams 会隐式起播,无需再 start
                } else {
                    mp.start()
                }
            }
            p.setOnCompletionListener { finish() }
            p.setOnErrorListener { _, what, extra ->
                VideoPlugin.reportPlayError("播放失败 (what=$what extra=$extra)")
                finish()
                true
            }
            p.prepareAsync()
        } catch (e: Exception) {
            VideoPlugin.reportPlayError("播放失败:${e.message}")
            finish()
        }
    }

    /** 视频帧按宽高比 letterbox:居中收进当前 surface 尺寸。 */
    private fun layoutVideoFrame(surfaceW: Int, surfaceH: Int) {
        val view = textureView ?: return
        val frame = videoFrame ?: return
        if (videoWidth <= 0 || videoHeight <= 0 || surfaceW <= 0 || surfaceH <= 0) return
        val scale = minOf(
            surfaceW.toFloat() / videoWidth,
            surfaceH.toFloat() / videoHeight,
        )
        val w = (videoWidth * scale).roundToInt()
        val h = (videoHeight * scale).roundToInt()
        frame.post {
            view.layoutParams = FrameLayout.LayoutParams(w, h, Gravity.CENTER)
            view.requestLayout()
        }
    }

    override fun onDestroy() {
        player?.run {
            try {
                stop()
            } catch (_: Exception) {
            }
            release()
        }
        player = null
        pendingSurface?.release()
        pendingSurface = null
        VideoPlugin.onPlayerClosed()
        super.onDestroy()
    }
}
