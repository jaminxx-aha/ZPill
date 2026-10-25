package com.jaminxx.nikonpill.bg

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * NikonPill 后台传输保活(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/background_transfer.dart(MethodChannel
 * `nikonpill/bg`):`ensureRunning` / `stop`,native 幂等。
 * ensureRunning → startForegroundService(TransferForegroundService);
 * 任一步失败(Android 12+ 后台启动限制、ROM 差异)不报错给 Dart ——
 * 按契约降级为「仅前台传输」,Log 留痕。
 */
class BgPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "BgPlugin"
        private const val CHANNEL = "nikonpill/bg"
    }

    private var context: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        when (call.method) {
            "ensureRunning" -> {
                if (ctx == null) {
                    result.success(null)
                    return
                }
                try {
                    ctx.startForegroundService(
                        Intent(ctx, TransferForegroundService::class.java)
                            .setAction(TransferForegroundService.ACTION_START)
                    )
                } catch (e: Exception) {
                    // Android 12+ 后台启动限制等:降级为仅前台传输
                    android.util.Log.w(TAG, "startForegroundService: $e")
                }
                result.success(null)
            }
            "stop" -> {
                if (ctx == null) {
                    result.success(null)
                    return
                }
                try {
                    ctx.stopService(Intent(ctx, TransferForegroundService::class.java))
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "stopService: $e")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
