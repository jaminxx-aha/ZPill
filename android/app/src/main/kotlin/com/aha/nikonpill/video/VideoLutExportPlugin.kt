package com.aha.nikonpill.video

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.ToInt16PcmAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.SingleColorLut
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.FrameworkMuxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * 视频 LUT 导出(`nikonpill/video_lut` 通道;Dart 契约
 * lib/platform/video_lut_export.dart)。
 *
 * Media3 Transformer 硬件导出(借 Camera_Bridge 实证思路,API 面一致):
 * - LUT = `SingleColorLut.createFromCube`(Media3 内置效果,免自写 GL
 *   shader);cube 由 Dart 侧 CubeLut.cubeDataRgba 产出 Float32 N³×4
 *   RGBA(红最快),这里折成 Media3 的 [红][绿][蓝] ARGB 嵌套数组。
 * - 音频必须挂 `ToInt16PcmAudioProcessor`:Zf 录 24bit LPCM(encoding
 *   21),Transformer 音频图编码 AAC 前要求 16bit PCM(参考仓实测教训)。
 * - `FrameworkMuxer.Factory()` 走系统 MediaMuxer:流式写标准 MP4 索引,
 *   免整档缓存也免默认 muxer 的 fragmented-MP4 零时长病。
 * - 进度 250ms 轮询 `getProgress`;`cancel` 走 Transformer.cancel(),
 *   结果以「cancelled」错误收场(Dart 侧按取消消费)。
 *
 * 线程:MethodChannel 回调在主线程,Transformer 构建与 start 同线程,
 * 进度轮询与监听回调也钉主线程 —— 全链单线程,无锁。终态只 settle 一次
 * (pending 清空后再来的回调全部无害)。
 */
@UnstableApi
class VideoLutExportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var transformer: Transformer? = null
    private var output: File? = null
    private var pending: MethodChannel.Result? = null

    /** 取消旗标:onError 收场时区分「用户取消」与真失败。 */
    private var cancelled = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private val progressPoll = object : Runnable {
        override fun run() {
            val t = transformer ?: return
            val holder = ProgressHolder()
            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                channel?.invokeMethod("onProgress", holder.progress.coerceIn(0, 99))
            }
            mainHandler.postDelayed(this, 250)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        cancelInFlight()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(true)
            "export" -> export(call, result)
            "cancel" -> {
                cancelInFlight()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun export(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "已有导出在途", null)
            return
        }
        val path = call.argument<String>("path") ?: ""
        val size = call.argument<Int>("size") ?: 0
        val cubeBytes = call.argument<ByteArray>("cube")
        val ctx = appContext
        if (path.isEmpty() || size < 2 || cubeBytes == null || ctx == null) {
            result.error("bad_args", "path/size/cube 缺失或非法", null)
            return
        }
        // Float32List 经 StandardMessageCodec 以小端 byte[] 过通道。
        val floats = ByteBuffer.wrap(cubeBytes)
            .order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val expected = size * size * size * 4
        if (floats.remaining() != expected) {
            result.error(
                "bad_cube",
                "cube 数据应为 $expected 浮点(${size}³×4),得 ${floats.remaining()}",
                null,
            )
            return
        }
        val out = File(ctx.cacheDir, "lut_export_${System.currentTimeMillis()}.mp4")
        out.delete()
        output = out
        pending = result

        val videoEffects = listOf<Effect>(SingleColorLut.createFromCube(cube(floats, size)))
        val edited = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(path))))
            // Zf 24bit LPCM → AAC 编码前压到 16bit(见类注)。
            .setEffects(Effects(listOf(ToInt16PcmAudioProcessor()), videoEffects))
            .build()
        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                settle(keepOutput = true) { it.success(mapOf("path" to out.absolutePath)) }
            }

            override fun onError(composition: Composition,
                                 exportResult: ExportResult,
                                 exception: ExportException) {
                val code = if (cancelled) "cancelled" else "export_failed"
                val msg = exception.errorCodeName ?: (exception.message ?: "导出失败")
                settle(keepOutput = false) { it.error(code, msg, null) }
            }
        }
        val t = Transformer.Builder(ctx)
            .setMuxerFactory(FrameworkMuxer.Factory())
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(listener)
            .build()
        transformer = t
        try {
            t.start(edited, out.absolutePath)
            mainHandler.postDelayed(progressPoll, 250)
        } catch (e: Exception) {
            settle(keepOutput = false) { it.error("export_failed", e.message ?: "start 失败", null) }
        }
    }

    /** 取消在途导出:删产物、结果以 cancelled 收场;无在途时无害。 */
    private fun cancelInFlight() {
        val t = transformer ?: return
        cancelled = true
        t.cancel()
        settle(keepOutput = false) { it.error("cancelled", "已取消", null) }
    }

    /**
     * 收场(终态恰好一次):停轮询、按 [keepOutput] 处置产物(成功保留
     * 交 Dart 导入;失败/取消删临时档)、清引用、回一次 [finish]。
     * 迟到的重复回调(pending 已空)全部无害。
     */
    private fun settle(keepOutput: Boolean, finish: (MethodChannel.Result) -> Unit) {
        mainHandler.removeCallbacks(progressPoll)
        cancelled = false
        if (!keepOutput) output?.delete()
        transformer = null
        output = null
        val p = pending ?: return
        pending = null
        finish(p)
    }

    /** FloatBuffer(N³×4 RGBA,红最快)→ Media3 cube [红][绿][蓝] ARGB。 */
    private fun cube(floats: java.nio.FloatBuffer, size: Int): Array<Array<IntArray>> {
        val plane = size * size
        fun rgba(r: Int, g: Int, b: Int, ch: Int): Float =
            floats.get(((b * plane + g * size + r) * 4) + ch)
        return Array(size) { r ->
            Array(size) { g ->
                IntArray(size) { b ->
                    val rr = (rgba(r, g, b, 0) * 255f).roundToInt().coerceIn(0, 255)
                    val gg = (rgba(r, g, b, 1) * 255f).roundToInt().coerceIn(0, 255)
                    val bb = (rgba(r, g, b, 2) * 255f).roundToInt().coerceIn(0, 255)
                    (0xFF shl 24) or (rr shl 16) or (gg shl 8) or bb
                }
            }
        }
    }

    companion object {
        private const val CHANNEL = "nikonpill/video_lut"
    }
}
