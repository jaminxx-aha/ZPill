package com.jaminxx.zpill.video

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.platform.PlatformView
import kotlin.math.roundToInt

/**
 * 内嵌视频平台视图(Android,`zpill/video-view`)。
 *
 * 对齐 iOS UiKitView(AVPlayerViewController)与 ohos OhosView(XComponent +
 * AVPlayer):查看器页内原层播放,不再另起 VideoActivity 全屏页。
 * TextureView + MediaPlayer,零新依赖(与全屏路同栈):
 * - 画面按视频宽高比 letterbox 居中,不裁切不拉伸(与 iOS aspect-fit
 *   同观感;全屏 Activity 同款算法);
 * - 未起播时 TextureView 透明 → 压在下层的海报帧可见(ohos 懒挂载
 *   同观感);首次起播把根视图转黑,视频外区域不再透出海报;
 * - 速率 ≠1(顺帧预览)静音(变速下音轨无意义,OpenZCine conform
 *   同款;iOS/全屏路同语义);
 * - 通道方法见 Dart 契约 lib/platform/video_player.dart:viewLoad
 *   (路径走方法通道,不走 creationParams)、viewControl、viewStatus、
 *   viewSeek。
 *
 * 生命周期:Flutter 侧 dispose 平台视图 → [dispose] 停播释放;播放器
 * 在 [load] 时创建并 prepareAsync(首次播放零准备延迟)。
 */
class EmbeddedVideoView(
    context: Context,
    private val viewId: Int,
) : PlatformView {
    private val root = FrameLayout(context)
    private val textureView = TextureView(context)

    private var player: MediaPlayer? = null
    private var surface: Surface? = null
    private var path: String? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var durationMs = 0
    private var prepared = false
    private var wantPlaying = false
    private var rate = 1.0
    private var disposed = false

    init {
        root.addView(
            textureView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            layoutVideoFrame()
        }
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                val s = Surface(surfaceTexture)
                surface = s
                player?.setSurface(s)
                if (wantPlaying) startIfReady()
            }

            override fun onSurfaceTextureSizeChanged(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                layoutVideoFrame()
            }

            override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
                player?.setSurface(null)
                surface?.release()
                surface = null
                return true
            }

            override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) {}
        }
    }

    override fun getView(): View = root

    /** 装载档案(同路径重复调用空转)。 */
    fun load(path: String) {
        if (disposed || this.path == path) return
        this.path = path
        releasePlayer()
        prepared = false
        durationMs = 0
        videoWidth = 0
        videoHeight = 0
        val mp = MediaPlayer()
        player = mp
        try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            mp.setDataSource(path)
            surface?.let { mp.setSurface(it) }
            mp.setOnVideoSizeChangedListener { _, w, h ->
                videoWidth = w
                videoHeight = h
                layoutVideoFrame()
            }
            mp.setOnPreparedListener { p ->
                if (disposed) return@setOnPreparedListener
                prepared = true
                durationMs = try {
                    p.duration
                } catch (_: Exception) {
                    0
                }
                applyRate(p)
                if (wantPlaying) startIfReady()
            }
            mp.setOnCompletionListener {
                wantPlaying = false
            }
            mp.setOnErrorListener { _, _, _ ->
                wantPlaying = false
                true // 吞掉错误:UI 靠状态轮询回落播放钮,不崩
            }
            mp.prepareAsync()
        } catch (_: Exception) {
            releasePlayer()
        }
    }

    /** 起播/暂停 + 速率(顺帧)。未就绪时只记意图,prepared 沿应用。 */
    fun control(playing: Boolean, rate: Double) {
        if (disposed) return
        wantPlaying = playing
        this.rate = if (rate.isFinite() && rate > 0) rate else 1.0
        val mp = player ?: return
        if (!prepared) return
        applyRate(mp)
        if (playing) {
            startIfReady()
        } else {
            try {
                if (mp.isPlaying) mp.pause()
            } catch (_: Exception) {
            }
        }
    }

    /** 位置/时长(秒)与播放态(播放控制浮层 250ms 轮询)。 */
    fun status(): Map<String, Any?> {
        val mp = player
        if (mp == null || !prepared || disposed) {
            return mapOf("position" to 0.0, "duration" to 0.0, "playing" to false)
        }
        val position = try {
            mp.currentPosition / 1000.0
        } catch (_: Exception) {
            0.0
        }
        val duration = try {
            mp.duration / 1000.0
        } catch (_: Exception) {
            0.0
        }
        val playing = try {
            mp.isPlaying
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "position" to position,
            "duration" to duration,
            "playing" to playing,
        )
    }

    /** 拖到 [position] 秒。 */
    fun seek(position: Double) {
        val mp = player ?: return
        if (!prepared || disposed) return
        try {
            mp.seekTo((position.coerceAtLeast(0.0) * 1000).toInt())
        } catch (_: Exception) {
        }
    }

    private fun startIfReady() {
        val mp = player ?: return
        if (!prepared || surface == null) return
        try {
            if (!mp.isPlaying) {
                // 起播即挡海报:视频外区域转黑(iOS AVKit 整面黑底同款)
                root.setBackgroundColor(0xFF000000.toInt())
                mp.start()
            }
        } catch (_: Exception) {
        }
    }

    /**
     * 速率与音量绑定:非 1 速率静音;回到 1 恢复音量。setPlaybackParams
     * 会隐式起播(Android 语义)—— 未要求播放就随即暂停。
     */
    private fun applyRate(mp: MediaPlayer) {
        try {
            val speed = if (rate == 1.0) 1f else rate.toFloat()
            mp.setVolume(
                if (speed == 1f) 1f else 0f,
                if (speed == 1f) 1f else 0f,
            )
            if (mp.playbackParams.speed != speed) {
                mp.playbackParams = mp.playbackParams.setSpeed(speed)
                if (!wantPlaying) mp.pause()
            }
        } catch (_: Exception) {
            // 个别编码不支持变速:保持 1x(顺帧是可选增强,不拦播放)
            try {
                mp.setVolume(1f, 1f)
            } catch (_: Exception) {
            }
        }
    }

    /** 视频帧按宽高比 letterbox:居中收进平台视图当前尺寸。 */
    private fun layoutVideoFrame() {
        if (disposed) return
        val w = root.width
        val h = root.height
        if (videoWidth <= 0 || videoHeight <= 0 || w <= 0 || h <= 0) return
        val scale = minOf(
            w.toFloat() / videoWidth,
            h.toFloat() / videoHeight,
        )
        val viewW = (videoWidth * scale).roundToInt().coerceAtLeast(1)
        val viewH = (videoHeight * scale).roundToInt().coerceAtLeast(1)
        val lp = textureView.layoutParams as? FrameLayout.LayoutParams ?: return
        if (lp.width == viewW && lp.height == viewH) return
        lp.width = viewW
        lp.height = viewH
        lp.gravity = Gravity.CENTER
        root.post {
            if (!disposed) textureView.layoutParams = lp
        }
    }

    private fun releasePlayer() {
        player?.let { mp ->
            try {
                mp.setSurface(null)
            } catch (_: Exception) {
            }
            try {
                if (mp.isPlaying) mp.stop()
            } catch (_: Exception) {
            }
            try {
                mp.release()
            } catch (_: Exception) {
            }
        }
        player = null
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        releasePlayer()
        surface?.release()
        surface = null
        VideoPlugin.unregisterEmbeddedView(viewId)
    }
}
