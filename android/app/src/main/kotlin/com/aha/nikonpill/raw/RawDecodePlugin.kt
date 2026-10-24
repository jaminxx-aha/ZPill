package com.aha.nikonpill.raw

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.aha.nikonpill.log.NativeLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 原生图片解码通道(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/raw_decoder.dart:`nikonpill/raw` 的
 * `decode` 把整档文件解码为 JPEG 字节返回,参数 `{path, maxPixelSize}`
 * (长边上限像素,缩放解码)。
 *
 * 调用方(本地图库缩略/查看器预览、相机相册高清席位 warmPreview)只在
 * 引擎解不了的格式上走这里:HIF/HEIF(尼康 .HIF = HEIF 容器,Flutter
 * 引擎无 HEIF 解码)与 NEF。能力矩阵:
 * - HIF/HEIC:平台 HEIF 解码器(API 28+,真机全系在册)直接解;irot/
 *   imir 方向由解码器自应用,产物即正立。**卓易通等容器若缺 HEVC 软解,
 *   BitmapFactory 回 null → 抛 decodeFailed**(调用方降级,容器硬缺口)。
 * - NEF 等真 RAW:平台解不了(回 null)→ 抛 decodeFailed;Dart 侧
 *   NEF 回内嵌 160×120 缩略兜底(lib/core/media/nef_thumb.dart),链路
 *   与 iOS/ohos 同构。
 *
 * 解码走 executor(45MP HIF 采样解码也要几百 ms,不得占主线程),结果
 * 经主线程 Handler 回传。JPEG 输入不走本通道(引擎原图源自理)。
 */
class RawDecodePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "RawDecodePlugin"
        private const val CHANNEL = "nikonpill/raw"
        private const val JPEG_QUALITY = 90
    }

    private var channel: MethodChannel? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ioExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "decode" -> {
                val path = call.argument<String>("path") ?: ""
                val maxPixelSize = call.argument<Int>("maxPixelSize") ?: 2560
                if (path.isEmpty() || !File(path).isFile) {
                    result.error("raw_error", "文件不存在:$path", null)
                    return
                }
                ioExecutor.execute {
                    try {
                        val jpeg = decodeToJpeg(path, maxPixelSize)
                        mainHandler.post { result.success(jpeg) }
                    } catch (e: Throwable) {
                        // Throwable:容器里解码器类可能整体缺失(NoClassDef
                        // FoundError 等 Error 族),通道边界必须永远回包,
                        // 不然 Dart 侧干挂。
                        mainHandler.post { result.error("decodeFailed", "$e", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    /// 解码为 JPEG 字节:一路 BitmapFactory(边界探格式 → inSampleSize
    /// 采样解码)→ 二路 ImageDecoder(API 28,边界失败/采样解码失败都
    /// 进二路 —— 容器里两条路是不同入口,漏桥可能只漏一条)→ 长边
    /// 钳制 → JPEG 压档。全程 NativeLog 留痕(容器里是否带 HEIF 解码
    /// 器只有这里能看见)。
    private fun decodeToJpeg(path: String, maxPixelSize: Int): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        NativeLog.i(
            "raw",
            "decode 边界: ${bounds.outWidth}x${bounds.outHeight} " +
                "mime=${bounds.outMimeType} max=$maxPixelSize ${File(path).name}",
        )
        // 一路:BitmapFactory。边界失败(-1)也先不放弃 —— 二路可能认。
        var bmp: Bitmap? = null
        if (bounds.outWidth > 0 && bounds.outHeight > 0) {
            val longEdge = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longEdge / (sample * 2) >= maxPixelSize) sample *= 2
            bmp = BitmapFactory.decodeFile(
                path,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        }
        // 二路:边界失败或采样解码 null 都进 ImageDecoder。
        if (bmp == null) {
            NativeLog.w("raw", "BitmapFactory 无产出,进 ImageDecoder 二路")
            bmp = decodeViaImageDecoder(path, maxPixelSize)
        }
        NativeLog.i("raw", "decode 出图: ${bmp.width}x${bmp.height} ${File(path).name}")
        val scaled = scaleToMaxLongEdge(bmp, maxPixelSize)
        try {
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            return out.toByteArray()
        } finally {
            if (scaled !== bmp) scaled.recycle()
            bmp.recycle()
        }
    }

    /// 长边超出上限补一次精确缩放(采样解码只有 2 的幂档,残留超限);
    /// 未超限原样返回(调用方按实例判等回收)。
    private fun scaleToMaxLongEdge(bmp: Bitmap, maxPixelSize: Int): Bitmap {
        val longEdge = maxOf(bmp.width, bmp.height)
        if (longEdge <= maxPixelSize) return bmp
        val scale = maxPixelSize.toFloat() / longEdge
        return Bitmap.createScaledBitmap(
            bmp,
            (bmp.width * scale).toInt().coerceAtLeast(1),
            (bmp.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }

    /// 二路回退:ImageDecoder(API 28+,与 BitmapFactory 不同的解码入口,
    /// 原生支持 HEIF 且自应用 irot)。卓易通容器 BitmapFactory 连 HEIF
    /// 容器都不识别(-1x-1 实测),若它只是漏了 BitmapFactory 这条桥,
    /// 这里还有机会;两条路都死才是真缺口。软件位图(compress 需可读)。
    private fun decodeViaImageDecoder(path: String, maxPixelSize: Int): Bitmap {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) {
            throw IllegalArgumentException("解码失败(解码器回 null):$path")
        }
        try {
            val src = android.graphics.ImageDecoder.createSource(File(path))
            val listener =
                android.graphics.ImageDecoder.OnHeaderDecodedListener { decoder, info, _ ->
                    decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
                    val size = info.size
                    val longEdge = maxOf(size.width, size.height)
                    if (longEdge > maxPixelSize) {
                        val scale = maxPixelSize.toFloat() / longEdge
                        decoder.setTargetSize(
                            (size.width * scale).toInt().coerceAtLeast(1),
                            (size.height * scale).toInt().coerceAtLeast(1),
                        )
                    }
                }
            return android.graphics.ImageDecoder.decodeBitmap(src, listener)
        } catch (e: Throwable) {
            // Throwable:ImageDecoder 类本身可能在容器里缺失(加载即
            // NoClassDefFoundError,Error 族不经 Exception)—— 类缺失
            // 本身就是容器图像栈残缺的铁证,原类名落日志。
            NativeLog.w("raw", "ImageDecoder 二路也失败:${e.javaClass.name}: ${e.message}")
            throw IllegalArgumentException("解码失败(BitmapFactory 与 ImageDecoder 双路均拒):$path")
        }
    }
}
