package com.jaminxx.nikonpill.gallery

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * NikonPill 相册/文件通道(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/gallery_saver.dart:
 * - tempDir()/thumbsDir()/previewsDir():cacheDir 下专用子目录(缓存,
 *   系统可回收;缩略图 LRU 与下载临时落盘用);
 * - downloadsDir():filesDir 下持久目录(「下载到应用」的目的地);
 * - dataDir():filesDir 下持久应用数据(客户端身份/配对记录);
 * - importFiles(items):批量导入系统相册 —— MediaStore 直写。
 *
 * Android 路径(minSdk 29,无系统对话框):
 * - 自有贡献(contentResolver.insert)免权限:RELATIVE_PATH 指定
 *   Pictures/NikonPill 或 Movies/NikonPill,IS_PENDING=1 → 拷字节 →
 *   IS_PENDING=0 原子可见,系统不会再弹「允许访问照片」;
 * - NEF 按官方 MIME image/x-nikon-nef 入 Images 集合(系统图库可能
 *   不渲染缩略图,但记录持久、可被其他应用读取;SnapBridge 同做法,
 *   待真机核对);
 * - 没有保存面板 → 不存在用户取消路径:要么全量导入成功,要么整体
 *   PlatformException(Dart 引擎侧按「未导入」落定并允许重排)。
 *
 * 文件拷贝走 executor(单文件可达 25MB+,不得占主线程),结果经主线程
 * Handler 回传。
 */
class GalleryPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        private const val TAG = "GalleryPlugin"
        private const val CHANNEL = "nikonpill/gallery"

        private const val TEMP_SUBDIR = "nikonpill"
        private const val THUMBS_SUBDIR = "nikonpill-thumbs"
        private const val PREVIEWS_SUBDIR = "nikonpill-previews"
        private const val DOWNLOADS_SUBDIR = "nikonpill-downloads"
        private const val DATA_SUBDIR = "nikonpill-data"

        private const val COPY_BUF_BYTES = 64 * 1024
    }

    private var channel: MethodChannel? = null
    private lateinit var appContext: Context
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ioExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "tempDir" -> cacheSubDir(TEMP_SUBDIR, result)
            "thumbsDir" -> cacheSubDir(THUMBS_SUBDIR, result)
            "previewsDir" -> cacheSubDir(PREVIEWS_SUBDIR, result)
            "downloadsDir" -> filesSubDir(DOWNLOADS_SUBDIR, result)
            "dataDir" -> filesSubDir(DATA_SUBDIR, result)
            "importFiles" -> importFiles(call, result)
            else -> result.notImplemented()
        }
    }

    /// 缓存目录(cacheDir)下专用子目录,不存在则创建;返回绝对路径。
    private fun cacheSubDir(sub: String, result: Result) {
        ensureDir(File(appContext.cacheDir, sub), result)
    }

    /// 持久目录(filesDir)下专用子目录。
    private fun filesSubDir(sub: String, result: Result) {
        ensureDir(File(appContext.filesDir, sub), result)
    }

    private fun ensureDir(dir: File, result: Result) {
        try {
            if (!dir.exists() && !dir.mkdirs() && !dir.exists()) {
                result.error("gallery_error", "mkdir 失败: ${dir.absolutePath}", null)
                return
            }
            result.success(dir.absolutePath)
        } catch (e: Exception) {
            result.error("gallery_error", "mkdir: $e", null)
        }
    }

    /**
     * 批量导入系统相册(MediaStore 直写)。
     * 入参(Dart invokeListMethod):[{path, kind('image'|'video'), filename}]。
     * 出参:content:// URI 列表(与入参等长;Android 无取消路径,不会返回空表)。
     */
    private fun importFiles(call: MethodCall, result: Result) {
        val raw = call.arguments
        if (raw !is List<*> || raw.isEmpty()) {
            result.error("gallery_error", "importFiles 参数须为非空列表", null)
            return
        }
        data class Req(val path: String, val kind: String, val filename: String)
        val requests = mutableListOf<Req>()
        for ((i, item) in raw.withIndex()) {
            if (item !is Map<*, *>) {
                result.error("gallery_error", "importFiles 第 $i 项不是 Map", null)
                return
            }
            val path = item["path"] as? String ?: ""
            val kind = item["kind"] as? String ?: ""
            val filename = item["filename"] as? String ?: ""
            if (path.isEmpty() || filename.isEmpty() || (kind != "image" && kind != "video")) {
                result.error("gallery_error", "importFiles 第 $i 项缺 path/filename 或 kind 非法", null)
                return
            }
            requests.add(Req(path, kind, filename))
        }
        Log.i(TAG, "importFiles: ${requests.size} 个文件,MediaStore 直写")
        ioExecutor.execute {
            val inserted = mutableListOf<Uri>()
            try {
                val uris = mutableListOf<String>()
                for (req in requests) {
                    val uri = insertOne(req.path, req.filename)
                    inserted.add(uri)
                    uris.add(uri.toString())
                }
                Log.i(TAG, "importFiles: ${uris.size}/${requests.size} 个 URI 落库")
                mainHandler.post { result.success(uris) }
            } catch (e: Exception) {
                // 尽力回滚已落库的半成品(含 IS_PENDING 残留),再整体报错:
                // Dart 引擎侧按「未导入」落定并允许重排,不允许部分成功。
                Log.e(TAG, "importFiles 失败: $e,回滚 ${inserted.size} 个")
                for (uri in inserted) {
                    try {
                        appContext.contentResolver.delete(uri, null, null)
                    } catch (e2: Exception) {
                        Log.w(TAG, "回滚 $uri 失败: $e2")
                    }
                }
                mainHandler.post {
                    result.error("gallery_error", "importFiles: $e", null)
                }
            }
        }
    }

    /// 单文件:insert(IS_PENDING=1)→ 拷字节 → IS_PENDING=0 → 返回 URI。
    private fun insertOne(path: String, filename: String): Uri {
        val resolver = appContext.contentResolver
        val mime = mimeFor(filename)
        val collection: Uri
        val relativePath: String
        if (mime.startsWith("image/")) {
            collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            relativePath = Environment.DIRECTORY_PICTURES + "/NikonPill"
        } else if (mime.startsWith("video/")) {
            collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            relativePath = Environment.DIRECTORY_MOVIES + "/NikonPill"
        } else {
            // 未知扩展名:入 Files 集合(任意 MIME),保持导入不断流
            collection = MediaStore.Files.getContentUri("external")
            relativePath = Environment.DIRECTORY_DOCUMENTS + "/NikonPill"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert 失败: $filename")
        try {
            BufferedInputStream(FileInputStream(path)).use { input ->
                resolver.openOutputStream(uri)?.use { out: OutputStream ->
                    val buf = ByteArray(COPY_BUF_BYTES)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                    }
                    out.flush()
                } ?: throw IllegalStateException("openOutputStream 失败: $filename")
            }
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, done, null, null)
            return uri
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (e2: Exception) {
                Log.w(TAG, "清理半成品 $uri 失败: $e2")
            }
            throw e
        }
    }

    /// 扩展名 → MIME(尼康产物优先;未知扩展名回落 octet-stream,
    /// 落 Files 集合不进图库集合,保持导入不断流)。
    private fun mimeFor(filename: String): String {
        val ext = filename.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg", "jpe" -> "image/jpeg"
            "png" -> "image/png"
            "heic", "heif" -> "image/heic"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "tif", "tiff" -> "image/tiff"
            "nef", "nrw" -> "image/x-nikon-nef"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "avi" -> "video/x-msvideo"
            "3gp" -> "video/3gpp"
            else -> "application/octet-stream"
        }
    }
}
