package com.aha.nikonpill.location

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
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
 * 连续流(ble_pair GPS 注入驱动源,与 iOS/ohos 同契约):EventChannel
 * `nikonpill/location/stream` + `startStream`/`stopStream`(幂等,distanceFilter
 * 3m)/`requestAlways`(两段式:先 FINE 后 BACKGROUND,Android 11+ 后台
 * 须单独申请,同包发必被系统拒)/`authStatus`(always/whenInUse/denied)。
 * 未授权起流 = 静默无事件(上层按「无定位」降级),绝不给错的坐标。
 *
 * 待真机核对:各 ROM 的 provider 启用差异、冷启动首次定位时长。
 */
class LocationPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        private const val TAG = "LocationPlugin"
        private const val CHANNEL = "nikonpill/location"
        private const val STREAM_EVENTS = "nikonpill/location/stream"
        private const val LOCATE_TIMEOUT_MS = 8000L
        private const val REQUEST_CODE = 7001
        private const val REQUEST_CODE_ALWAYS = 7003
        private const val STREAM_MIN_DISTANCE_M = 3f
    }

    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    private var pendingPermission: MethodChannel.Result? = null
    private var permissionListener: PluginRegistry.RequestPermissionsResultListener? = null
    private var locating = false

    // 连续流
    private var streamSink: EventChannel.EventSink? = null
    private var streamRunning = false
    private var lastStreamFix: Map<String, Any?>? = null
    private var pendingAlways: MethodChannel.Result? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        EventChannel(binding.binaryMessenger, STREAM_EVENTS).setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        stopStreamNative()
        streamSink = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        permissionListener = PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
            when (requestCode) {
                REQUEST_CODE -> {
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
                REQUEST_CODE_ALWAYS -> {
                    permissionListener = null
                    val pending = pendingAlways
                    pendingAlways = null
                    if (pending != null) {
                        continueAlways(pending)
                    }
                    true
                }
                else -> false
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
            "startStream" -> {
                startStreamNative()
                result.success(null)
            }
            "stopStream" -> {
                stopStreamNative()
                result.success(null)
            }
            "requestAlways" -> requestAlways(result)
            "authStatus" -> result.success(authStatus())
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

    // ------------------------------------------------------------------
    // 连续定位流(GPS 注入驱动源;未授权静默无事件,上层按「无定位」降级)
    // ------------------------------------------------------------------

    private val streamListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val payload = mapOf(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "altitude" to if (location.hasAltitude()) location.altitude else null,
            )
            lastStreamFix = payload
            streamSink?.success(payload)
        }

        @Deprecated("Deprecated in Java")
        override fun onProviderDisabled(provider: String) {}

        @Deprecated("Deprecated in Java")
        override fun onProviderEnabled(provider: String) {}

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    override fun onListen(args: Any?, events: EventChannel.EventSink?) {
        streamSink = events
        startStreamNative()
        lastStreamFix?.let { events?.success(it) }
    }

    override fun onCancel(args: Any?) {
        streamSink = null
        stopStreamNative()
    }

    /** 幂等;未授权静默。 */
    private fun startStreamNative() {
        if (streamRunning) return
        val ctx = context ?: return
        if (ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            return
        }
        val providers = try {
            lm.getProviders(true).filter { it != LocationManager.PASSIVE_PROVIDER }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "getProviders: $e")
            emptyList()
        }
        if (providers.isEmpty()) {
            return
        }
        try {
            providers.forEach {
                lm.requestLocationUpdates(
                    it, 0L, STREAM_MIN_DISTANCE_M, streamListener, Looper.getMainLooper(),
                )
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "requestLocationUpdates: $e")
            return
        }
        streamRunning = true
    }

    private fun stopStreamNative() {
        val ctx = context ?: return
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        try {
            lm.removeUpdates(streamListener)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "removeUpdates: $e")
        }
        streamRunning = false
        lastStreamFix = null
    }

    // ------------------------------------------------------------------
    // 两段式「始终」授权:FINE 未给先要 FINE;FINE 已有则单发 BACKGROUND
    // (Android 11+ 后台必须与前台分两次申请,同包发必被系统直接拒)。
    // 拒绝静默收口(与 iOS requestAlways 同语义;设置页按钮可重试)。
    // ------------------------------------------------------------------

    private fun requestAlways(result: MethodChannel.Result) {
        val ctx = context
        val act = activity
        if (ctx == null || act == null || pendingAlways != null) {
            result.success(null)
            return
        }
        val fine = ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val bg = Build.VERSION.SDK_INT < 29 ||
            ctx.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (fine && bg) {
            result.success(null)
            return
        }
        pendingAlways = result
        val want = if (fine) {
            arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }
        act.requestPermissions(want, REQUEST_CODE_ALWAYS)
    }

    private fun continueAlways(pending: MethodChannel.Result) {
        val ctx = context
        val act = activity
        val fine = ctx != null &&
            ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val bg = Build.VERSION.SDK_INT < 29 || (ctx != null &&
            ctx.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED)
        if (fine && !bg && act != null) {
            pendingAlways = pending
            act.requestPermissions(
                arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                REQUEST_CODE_ALWAYS,
            )
            return
        }
        pending.success(null)
    }

    /** always / whenInUse / denied(Android 无持久「未问过」态,未给一律 denied)。 */
    private fun authStatus(): String? {
        val ctx = context ?: return null
        val fine = ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val bg = Build.VERSION.SDK_INT < 29 ||
            ctx.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return when {
            fine && bg -> "always"
            fine -> "whenInUse"
            else -> "denied"
        }
    }
}
