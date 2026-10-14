package com.aha.nikonpill.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 程序化加入 Wi-Fi(`nikonpill/network` 方法 join/release;Dart 契约
 * lib/platform/network_monitor.dart 的 WifiJoiner)。
 *
 * BLE→WiFi 交接用(SnapBridge 同款):0x2004 凭据 → 写 0x2005 断 BLE →
 * join 相机热点 → PTP/IP。实现 = WifiNetworkSpecifier + requestNetwork
 * (minSdk 29 正好是其门槛):onAvailable 沿 bindProcessToNetwork 把
 * 进程默认路由绑到相机网(specifier 网络无互联网,不绑则 Dart socket
 * 出不去相机网段);release 解绑 + 注销请求,恢复外网路由。
 *
 * 系统可能弹「设备连接」确认框,用户拒绝走 onUnavailable,如实回报。
 * join 未定局前重复调用 = 旧请求先 release(结果以 superseded 收场),
 * 新请求顶上。
 */
class NetworkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var connectivity: ConnectivityManager? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 一次性 join 结果(照 BlePlugin pending-Result 模式:只回一次)。
    private var pendingJoin: MethodChannel.Result? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var boundNetwork: Network? = null
    private var watchdog: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        connectivity = binding.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        releaseNetwork()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "join" -> {
                val ssid = call.argument<String>("ssid") ?: ""
                val password = call.argument<String>("password") ?: ""
                val security = call.argument<Int>("security") ?: 0
                join(ssid, password, security, result)
            }
            "release" -> {
                releaseNetwork()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun join(ssid: String, password: String, security: Int, result: MethodChannel.Result) {
        val cm = connectivity ?: run {
            result.success(mapOf("ok" to false, "reason" to "no connectivity service"))
            return
        }
        // 重复 join:旧请求放掉(pending 以 superseded 收场),新的顶上。
        releaseNetwork()
        pendingJoin = result

        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid)
        // 0x2004 安全字节:0x01 开放 / 0x02 WPA2 / 0x03 WPA3 / 0x04
        // WPA2+WPA3 / 0x00 未定义。密码空一律按开放;0x03 走 WPA3,
        // 其余有密码走 WPA2(0x04 取兼容侧)。
        if (password.isNotEmpty()) {
            if (security == 0x03) spec.setWpa3Passphrase(password)
            else spec.setWpa2Passphrase(password)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec.build())
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    // 绑进程默认路由:相机网无互联网,不绑则 Dart socket
                    // 不走相机网段(= SnapBridge 反编译里的「绑网卡」)。
                    cm.bindProcessToNetwork(network)
                    boundNetwork = network
                    settleJoin(mapOf("ok" to true))
                }
            }

            override fun onUnavailable() {
                mainHandler.post {
                    settleJoin(mapOf("ok" to false, "reason" to "unavailable"))
                }
            }
        }
        networkCallback = callback
        try {
            cm.requestNetwork(request, callback)
        } catch (e: Exception) {
            settleJoin(mapOf("ok" to false, "reason" to (e.message ?: "request failed")))
            return
        }
        // 看门狗:30s 未定局按超时收场(热点出现需几秒;Result 必须回,
        // 否则 Dart 侧 Future 悬挂)。
        val wd = Runnable {
            settleJoin(mapOf("ok" to false, "reason" to "timeout"))
        }
        watchdog = wd
        mainHandler.postDelayed(wd, 30_000)
    }

    /// join 结果只回一次;watchdog 一并撤。
    private fun settleJoin(payload: Map<String, Any?>) {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        watchdog = null
        val pending = pendingJoin ?: return
        pendingJoin = null
        pending.success(payload)
    }

    /// 解绑进程路由 + 注销请求;幂等,未持有无操作。引擎脱离时 pending
    /// 以 released 收场(防 Dart 侧 Future 悬挂)。
    private fun releaseNetwork() {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        watchdog = null
        networkCallback?.let { cb ->
            try {
                connectivity?.unregisterNetworkCallback(cb)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "unregisterNetworkCallback: $e")
            }
        }
        networkCallback = null
        if (boundNetwork != null) {
            try {
                connectivity?.bindProcessToNetwork(null)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "bindProcessToNetwork(null): $e")
            }
        }
        boundNetwork = null
        pendingJoin?.success(mapOf("ok" to false, "reason" to "released"))
        pendingJoin = null
    }

    companion object {
        private const val CHANNEL = "nikonpill/network"
        private const val TAG = "NetworkPlugin"
    }
}
