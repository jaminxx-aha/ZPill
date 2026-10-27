package com.jaminxx.zpill.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * 程序化加入 Wi-Fi(`zpill/network` 方法 join/release;Dart 契约
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
 *
 * join 成功 payload 增 `gateway`(点分 IPv4,拿不到不带键):specifier
 * 网络是相机当热点的 AP,DHCP 网关即相机本机 IP —— Dart 侧据此替代
 * 硬编码 192.168.1.1(不同相机网段不同;Camera_Bridge 思路)。
 */
class NetworkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var connectivity: ConnectivityManager? = null
    private var appContext: Context? = null
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
        appContext = binding.applicationContext
        connectivity = binding.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
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
                    // 网关随 join 定局一并回报(拿不到不带键,Dart 回落
                    // 默认 IP —— 与不带网关的旧行为等价)。
                    val payload = mutableMapOf<String, Any?>("ok" to true)
                    readGateway(cm, network)?.let { payload["gateway"] = it }
                    settleJoin(payload)
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

    /// 读 join 网络的 DHCP 网关(点分 IPv4;拿不到 null)。按健壮序两路:
    /// ① API 30+ `LinkProperties.dhcpServerAddress` —— 直接管到刚 join
    ///    上的 [network],不受系统默认 Wi-Fi 误导(minSdk 29,须运行时
    ///    守卫);
    /// ② 回落 `WifiManager.dhcpInfo.gateway` —— 系统 Wi-Fi 最近一次租约
    ///    的快照,join 沿刚完成的就是相机 AP 的租约(时序上略竞态,
    ///    尽力而为)。
    private fun readGateway(cm: ConnectivityManager, network: Network): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val addr = try {
                cm.getLinkProperties(network)?.dhcpServerAddress
            } catch (e: Exception) {
                android.util.Log.w(TAG, "getLinkProperties: $e")
                null
            }
            // 只收 IPv4(相机 PTP/IP 是点分 v4);hostAddress 即点分串。
            if (addr is Inet4Address) {
                val s = addr.hostAddress
                if (!s.isNullOrEmpty()) {
                    return s
                }
            }
        }
        return dhcpInfoGateway()
    }

    /// ② 的取法。`DhcpInfo.gateway` 是 int,四字节**小端**约定:点分首段
    /// 压在最低位字节 —— 192.168.1.1 存 0x0101A8C0(字节 C0 A8 01 01
    /// 倒压)。这与 `InetAddress.getAddress()` 的大端字节序恰好相反(经典
    /// 坑:照 getAddress 的方向组字节会解出 1.0.168.192)。方向自证:
    /// 0x0101A8C0 自低位起取字节 = C0·A8·01·01 = 192.168.1.1。0 = 无
    /// 租约,负值 = 末段 ≥128 或全 1(-1 即 0xFFFFFFFF),对相机网关皆
    /// 非可信值,一律当「拿不到」。
    private fun dhcpInfoGateway(): String? {
        val raw = try {
            val wm = appContext?.getSystemService(Context.WIFI_SERVICE)
                    as? WifiManager ?: return null
            wm.dhcpInfo?.gateway ?: 0
        } catch (e: Exception) {
            android.util.Log.w(TAG, "dhcpInfo: $e")
            return null
        }
        if (raw <= 0) {
            return null
        }
        return "${raw and 0xff}.${(raw ushr 8) and 0xff}." +
            "${(raw ushr 16) and 0xff}.${(raw ushr 24) and 0xff}"
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
        private const val CHANNEL = "zpill/network"
        private const val TAG = "NetworkPlugin"
    }
}
