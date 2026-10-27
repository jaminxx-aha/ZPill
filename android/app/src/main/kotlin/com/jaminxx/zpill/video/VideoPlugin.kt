package com.jaminxx.zpill.video

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max

/**
 * ZPill 视频(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/video_player.dart(MethodChannel
 * `zpill/video`),当前覆盖全屏播放、抽帧与帧率探测;内嵌平台视图
 * 尚未落地,调用方按全屏路径回退:
 *
 * - `thumbnail({path, maxPixelSize})`:取 0.1s 处一帧(iOS 取同点位避
 *   纯黑首帧),按 METADATA_KEY_VIDEO_ROTATION 旋转正立(与 iOS
 *   appliesPreferredTrackTransform 同语义),长边压到 maxPixelSize 内,
 *   JPEG(85)回传 ByteArray —— Dart 侧 FlutterStandardTypedData 收。
 * - `frameRate({path})`:METADATA_KEY_CAPTURE_FRAMERATE 是拍摄帧率
 *   (API 28+),多数设备只回整档;退路 = 帧数/时长估算,拿不到 = null
 *   (调用方不设顺帧门,直放)。
 * - `play({path, rate})`:MediaPlayer + VideoActivity 全屏播放。
 *
 * 线程:通道调用在主线程,retriever 抽帧是重活 —— 切后台队列执行,
 * 结果回主线程交付(MethodChannel.Result 线程契约)。
 */
class VideoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "zpill/video"
        private const val THUMB_TIME_US = 100_000L // 0.1s,避纯黑首帧

        /// 全屏播放的待交付通道结果(VideoActivity 关闭/出错时交付;
        /// 插件与 Activity 同进程,静态槽直连 —— ohos SaveSession 同款)。
        @Volatile
        private var playResult: MethodChannel.Result? = null

        /// 播放页关闭:交付 success(null)(通道 Future 在播放器关闭时
        /// 完成的契约)。
        fun onPlayerClosed() {
            val r = playResult ?: return
            playResult = null
            try {
                r.success(null)
            } catch (_: Exception) {
            }
        }

        /// 播放出错:交付 error(转「该平台暂不支持」类提示,上层兜住)。
        fun reportPlayError(message: String) {
            val r = playResult ?: return
            playResult = null
            try {
                r.error("play_failed", message, null)
            } catch (_: Exception) {
            }
        }
    }

    private var channel: MethodChannel? = null
    private var executor: java.util.concurrent.ExecutorService? = null
    private var handler: android.os.Handler? = null
    private var engineContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        handler = android.os.Handler(android.os.Looper.getMainLooper())
        engineContext = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        executor?.shutdown()
        executor = null
        handler = null
        engineContext = null
    }

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "play" -> {
                val path = call.argument<String>("path")
                val rate = call.argument<Double>("rate") ?: 1.0
                if (path == null) {
                    result.error("bad_args", "play 需要 path", null)
                    return
                }
                if (playResult != null) {
                    result.error("busy", "已有全屏播放在进行", null)
                    return
                }
                val context = engineContext ?: run {
                    result.error("unavailable", "engine detached", null)
                    return
                }
                playResult = result
                val intent = android.content.Intent(context, VideoActivity::class.java)
                    .putExtra(VideoActivity.EXTRA_PATH, path)
                    .putExtra(VideoActivity.EXTRA_RATE, rate)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                } catch (e: Exception) {
                    playResult = null
                    result.error("play_failed", "无法打开播放页:${e.message}", null)
                }
            }
            "thumbnail" -> {
                val path = call.argument<String>("path")
                val maxPixelSize = call.argument<Int>("maxPixelSize") ?: 512
                if (path == null) {
                    result.error("bad_args", "thumbnail 需要 path", null)
                    return
                }
                val task = executor ?: run {
                    result.error("unavailable", "engine detached", null)
                    return
                }
                task.execute {
                    val bytes = extractThumbnail(path, maxPixelSize)
                    handler?.post {
                        if (bytes != null) {
                            result.success(bytes)
                        } else {
                            result.error("thumbnail_failed", "抽帧失败:$path", null)
                        }
                    }
                }
            }
            "frameRate" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "frameRate 需要 path", null)
                    return
                }
                val task = executor ?: run {
                    result.error("unavailable", "engine detached", null)
                    return
                }
                task.execute {
                    val rate = probeFrameRate(path)
                    handler?.post {
                        if (rate != null) result.success(rate) else result.success(null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** 抽帧:0.1s 处 + 旋转正立 + 长边压 [maxPixelSize],JPEG 字节。 */
    private fun extractThumbnail(path: String, maxPixelSize: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            var frame = retriever.getFrameAtTime(
                THUMB_TIME_US,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null

            // 按拍摄方向正立(部分机型 getFrameAtTime 不自动转)
            val rotation = try {
                retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0
            } catch (_: Exception) {
                0
            }
            if (rotation != 0) {
                val m = Matrix().apply { postRotate(rotation.toFloat()) }
                frame = Bitmap.createBitmap(
                    frame, 0, 0, frame.width, frame.height, m, true,
                )
            }

            // 长边压档(已小于目标则原样)
            val longSide = max(frame.width, frame.height)
            if (longSide > maxPixelSize) {
                val scale = maxPixelSize.toFloat() / longSide
                frame = Bitmap.createScaledBitmap(
                    frame,
                    max(1, (frame.width * scale).toInt()),
                    max(1, (frame.height * scale).toInt()),
                    true,
                )
            }
            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, 85, out)
            return out.toByteArray()
        } catch (_: Exception) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    /** 帧率探测:拍摄帧率元数据优先,退路帧数/时长估算;拿不到 = null。 */
    private fun probeFrameRate(path: String): Double? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val captured = try {
                retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE,
                )?.toFloatOrNull()
            } catch (_: Exception) {
                null
            }
            if (captured != null && captured > 0f) return captured.toDouble()

            val frameCount = try {
                retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT,
                )?.toIntOrNull()
            } catch (_: Exception) {
                null
            }
            val durationMs = try {
                retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toIntOrNull()
            } catch (_: Exception) {
                null
            }
            if (frameCount != null && frameCount > 0 && durationMs != null && durationMs > 0) {
                val rate = frameCount.toDouble() / (durationMs / 1000.0)
                if (rate > 0) return rate
            }
            return null
        } catch (_: Exception) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }
}
