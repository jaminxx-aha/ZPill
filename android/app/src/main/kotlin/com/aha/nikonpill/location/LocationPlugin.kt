package com.aha.nikonpill.location

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * NikonPill 位置服务(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/location_host.dart(MethodChannel
 * `nikonpill/location`):`current` → [lat, lon](double)或 null。
 * null 语义 = 本次无定位,上层按「照片不加 GPS」降级,绝不给错的坐标。
 *
 * 定位策略与 iOS/ohos 对齐:只取新鲜定位(requestLocationUpdates 首回调
 * 胜出),不用 getLastKnownLocation(可能是几小时前的位置,错比缺糟)。
 * GPS + NETWORK(启用中的 provider 全发)赛马,8s 超时 → null。
 *
 * 权限:仅 ACCESS_FINE_LOCATION 算「有权限」(粗定位 ≈ 数公里,照片
 * GPS 无意义);未授权时弹系统框,拒绝/并发请求 → null。只用 framework
 * API(Activity.requestPermissions / Context.checkSelfPermission),
 * 不引 androidx。
 *
 * 待真机核对:各 ROM 的 provider 启用差异、冷启动首次定位时长。
 */
class LocationPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "LocationPlugin"
        private const val CHANNEL = "nikonpill/location"
        private const val LOCATE_TIMEOUT_MS = 8000L
        private const val REQUEST_CODE = 7001
    }

    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    private var pendingPermission: MethodChannel.Result? = null
    private var permissionListener: PluginRegistry.RequestPermissionsResultListener? = null
    private var locating = false

    private val mainHandler = Handler(Looper.getMainLooper())

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

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        permissionListener = PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
            if (requestCode != REQUEST_CODE) {
                false
            } else {
                permissionListener = null
                val pending = pendingPermission
                pendingPermission = null
                if (pending != null) {
                    if (grantResults.isNotEmpty() &&
                        grantResults.zip(permissions).any { (g, p) ->
                            p == Manifest.permission.ACCESS_FINE_LOCATION && g == PackageManager.PERMISSION_GRANTED
                        }
                    ) {
                        startLocate(pending)
                    } else {
                        pending.success(null)
                    }
                }
                true
            }
        }.also { binding.addRequestPermissionsResultListener(it) }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
        permissionListener = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> current(result)
            else -> result.notImplemented()
        }
    }

    private fun current(result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.success(null)
            return
        }
        if (ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startLocate(result)
            return
        }
        val act = activity
        if (act == null || pendingPermission != null) {
            // 无 Activity(引擎后台态)或已有并发请求:直接无定位
            result.success(null)
            return
        }
        pendingPermission = result
        act.requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQUEST_CODE,
        )
    }

    private fun startLocate(result: MethodChannel.Result) {
        if (locating) {
            result.success(null)
            return
        }
        val ctx = context
        val lm = ctx?.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.success(null)
            return
        }
        val providers = try {
            lm.getProviders(true).filter { it != LocationManager.PASSIVE_PROVIDER }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "getProviders: $e")
            emptyList()
        }
        if (providers.isEmpty()) {
            result.success(null)
            return
        }

        locating = true
        val listener = object : LocationListener {
            var delivered = false

            override fun onLocationChanged(location: Location) {
                if (delivered) return
                delivered = true
                cleanup()
                result.success(listOf(location.latitude, location.longitude))
            }

            @Deprecated("Deprecated in Java")
            override fun onProviderDisabled(provider: String) {}

            @Deprecated("Deprecated in Java")
            override fun onProviderEnabled(provider: String) {}

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

            fun cleanup() {
                mainHandler.removeCallbacksAndMessages(null)
                try {
                    lm.removeUpdates(this)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "removeUpdates: $e")
                }
                locating = false
            }
        }
        try {
            providers.forEach { lm.requestLocationUpdates(it, 0L, 0f, listener, Looper.getMainLooper()) }
        } catch (e: SecurityException) {
            android.util.Log.w(TAG, "requestLocationUpdates: $e")
            listener.cleanup()
            result.success(null)
            return
        } catch (e: Exception) {
            android.util.Log.w(TAG, "requestLocationUpdates: $e")
            listener.cleanup()
            result.success(null)
            return
        }
        mainHandler.postDelayed({
            if (!listener.delivered) {
                listener.delivered = true
                listener.cleanup()
                result.success(null)
            }
        }, LOCATE_TIMEOUT_MS)
    }
}
