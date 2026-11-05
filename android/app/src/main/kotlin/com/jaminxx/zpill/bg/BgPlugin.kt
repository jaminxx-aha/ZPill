package com.jaminxx.zpill.bg

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * ZPill 后台传输保活(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/background_transfer.dart(MethodChannel
 * `zpill/bg`):`ensureRunning` / `stop`,native 幂等。
 * ensureRunning → startForegroundService(TransferForegroundService);
 * 任一步失败(Android 12+ 后台启动限制、ROM 差异)不报错给 Dart ——
 * 按契约降级为「仅前台传输」,Log 留痕。
 *
 * Android 13+ 另需 POST_NOTIFICATIONS 运行时授权:Manifest 声明不足,
 * 未授权时前台服务通知会被系统隐藏(传输本身仍跑)。首次 ensureRunning
 * 在前台时补一次系统请求;拒绝不挡传输,后续不再骚扰。API 31 本机走
 * 不到该分支,待 Android 13+ 真机验。
 */
class BgPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "BgPlugin"
        private const val CHANNEL = "zpill/bg"
        private const val REQUEST_NOTIFICATIONS = 7004
    }

    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    /// 13+ 通知权限每进程只问一次:拒绝后不随每次传输反复弹。
    private var notificationAsked = false

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
                maybeRequestNotificationPermission(ctx)
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
            "setScreenAwake" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                val act = activity
                if (act == null) {
                    result.success(null)
                    return
                }
                act.runOnUiThread {
                    try {
                        if (enabled) {
                            act.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            act.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "setScreenAwake: $e")
                    }
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /// Android 13+ POST_NOTIFICATIONS 运行时请求:仅前台首次传输问一次。
    /// 无 Activity(后台)/已授权/已问过直接跳过;请求结果不影响传输。
    private fun maybeRequestNotificationPermission(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        if (notificationAsked) return
        val act = activity ?: return
        notificationAsked = true
        act.runOnUiThread {
            try {
                act.requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_NOTIFICATIONS,
                )
            } catch (e: Exception) {
                android.util.Log.w(TAG, "requestPermissions(POST_NOTIFICATIONS): $e")
            }
        }
    }

    // ActivityAware:setScreenAwake 需要 Activity 的 Window(application
    // context 拿不到窗口标志)。其余后台任务能力仍只用 context。
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
