package com.jaminxx.zpill.nsd

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * ZPill mDNS 相机发现(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/nsd_scanner.dart(`zpill/nsd` +
 * `zpill/nsd/events`):浏览 `_ptp._tcp` 并解析出 IP/端口/TXT,
 * found/lost 事件经 EventChannel 上报。
 *
 * Android API 要点(NsdManager,minSdk 29,真机待验证):
 * - serviceType **带尾点**('_ptp._tcp.',Android 惯例;iOS 同带尾点,
 *   ohos @ohos.net.mdns 不带 —— 三端各按平台文档,待真机核对);
 * - resolveService 同一时刻只允许一个在飞(老实现 MAX=1 硬限制,
 *   超发直接 onResolveFailed)→ 发现→解析之间挂**串行队列**;
 * - API 34 起 resolveService/host 已弃用但仍可用;TXT 读取走公有
 *   getAttributes()(getTxtRecord 一直是 hidden API,编译不可见),
 *   真机核对后如有问题再切 registerServiceInfoCallback 新路线;
 * - resolve 成功但 host 为 null(无 A 记录)→ 按空 host 上报,
 *   Dart 侧过滤无 host 项(与 ohos 同构);
 * - onStartDiscoveryFailed 只记日志不上抛:无 Wi-Fi/权限被拒时表现
 *   为扫不到,由 UI 文案兜底。
 *
 * 契约要点(与 iOS NsdPlugin.swift / ohos NsdPlugin.ets 同构):
 * - 纯 DNS-SD 解析,绝不向相机发 TCP 连接(单连接服务器,探测性
 *   连接会被保持并呛住后续连接);
 * - start 幂等:先停再启并清空旧记账;
 * - resolve 失败回滚记账,等 mDNS 周期重播再试;
 * - Dart 尚未挂监听的窗口期事件丢弃即可(found 随 mDNS 周期重播)。
 *
 * 状态全部约束在主线程:发现/解析回调统一经主线程 Handler 投递,
 * start/stop 本身在 MethodChannel 主线程回调里。
 */
class NsdPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val TAG = "NsdPlugin"
        private const val CHANNEL = "zpill/nsd"
        private const val EVENTS_CHANNEL = "zpill/nsd/events"

        /// 浏览的服务类型(PTP/IP,SRV 端口 15740;带尾点,待真机核对)。
        private const val SERVICE_TYPE = "_ptp._tcp."

        /// Dart 契约的兜底端口(DiscoveredIpCamera.fromMap 的默认值同源)。
        private const val DEFAULT_PORT = 15740
    }

    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private lateinit var nsdManager: NsdManager
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 当前发现会话的 listener(持引用,字段置 null 即视为无会话)。
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var searching = false

    /// 已知服务实例名(serviceFound 去重;lost 后移除,resolve 失败回滚)。
    private val known = mutableSetOf<String>()

    /// 串行解析队列 + 在飞标志(NsdManager 单 resolve 限制)。
    private val pendingResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        nsdManager = binding.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        events?.setStreamHandler(null)
        events = null
        sink = null
        teardownDiscovery()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> stop(result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        // 与 ohos/iOS 同构:取消订阅不停浏览,只断事件出口
        // (found 随 mDNS 周期重播,重订阅即可恢复)。
        sink = null
    }

    /// 开始浏览(幂等:已激活先停,清空旧记账再启)。
    private fun start(result: Result) {
        try {
            pauseDiscovery()
            known.clear()
            pendingResolve.clear()
            val listener = createDiscoveryListener()
            discoveryListener = listener
            searching = true
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            result.success(null)
        } catch (e: Exception) {
            searching = false
            result.error("nsd_error", "start: $e", null)
        }
    }

    /// 停止浏览(幂等)。
    private fun stop(result: Result) {
        pauseDiscovery()
        known.clear()
        pendingResolve.clear()
        result.success(null)
    }

    private fun pauseDiscovery() {
        val listener = discoveryListener
        discoveryListener = null
        searching = false
        if (listener != null) {
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (e: Exception) {
                Log.w(TAG, "stopServiceDiscovery: $e")
            }
        }
    }

    /// 彻底拆解(引擎分离):停浏览并清空全部记账。
    private fun teardownDiscovery() {
        pauseDiscovery()
        known.clear()
        pendingResolve.clear()
    }

    private fun createDiscoveryListener(): NsdManager.DiscoveryListener =
        object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                mainHandler.post { searching = true }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                mainHandler.post { searching = false }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                mainHandler.post {
                    Log.w(TAG, "discovery 启动失败 rc=$errorCode(无 Wi-Fi/权限时表现为扫不到,UI 文案兜底)")
                    searching = false
                    discoveryListener = null
                }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                mainHandler.post {
                    Log.w(TAG, "discovery 停止失败 rc=$errorCode")
                    searching = false
                    discoveryListener = null
                }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                mainHandler.post { handleFound(serviceInfo) }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                mainHandler.post { handleLost(serviceInfo) }
            }
        }

    /// serviceFound:去重 → 入队 resolve(串行)→ 解析完成上报。
    private fun handleFound(info: NsdServiceInfo) {
        val name = info.serviceName ?: return
        if (name.isEmpty() || !known.add(name)) {
            return
        }
        pendingResolve.add(info)
        drainResolveQueue()
    }

    /// serviceLost:仅在已知(上报过/在解析)时报丢失,与 iOS/ohos 同构。
    private fun handleLost(info: NsdServiceInfo) {
        val name = info.serviceName ?: return
        if (known.remove(name)) {
            emit(mapOf("event" to "lost", "name" to name))
        }
    }

    /// NsdManager 同一时刻只允许一个 resolveService 在飞 → 串行出队。
    private fun drainResolveQueue() {
        if (resolving || pendingResolve.isEmpty()) {
            return
        }
        val target = pendingResolve.removeFirst()
        // 用发现时的原始实例名记账:个别 Android 版本 resolve 回调里的
        // serviceName 是全限定名,不能当 key。
        val origName = target.serviceName
        if (origName.isNullOrEmpty()) {
            drainResolveQueue()
            return
        }
        resolving = true
        val listener = object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                mainHandler.post {
                    resolving = false
                    if (origName in known) {
                        emitFound(origName, resolved)
                    }
                    // 不在 known:等待期间已 lost/停止,丢弃
                    drainResolveQueue()
                }
            }

            override fun onResolveFailed(failed: NsdServiceInfo, errorCode: Int) {
                mainHandler.post {
                    resolving = false
                    Log.w(TAG, "resolveService(${failed.serviceName}) 失败 rc=$errorCode,等 mDNS 重播")
                    known.remove(origName)
                    drainResolveQueue()
                }
            }
        }
        try {
            // API 34 弃用但仍可用(见类头注);真机核对后再评估新路线
            @Suppress("DEPRECATION")
            nsdManager.resolveService(target, listener)
        } catch (e: Exception) {
            resolving = false
            Log.w(TAG, "resolveService 抛异常: $e")
            known.remove(origName)
            drainResolveQueue()
        }
    }

    /// 解析完成 → found 事件(host 为 null 按 '' 上报,Dart 侧过滤)。
    @Suppress("DEPRECATION")
    private fun emitFound(name: String, info: NsdServiceInfo) {
        val txt = HashMap<String, String>()
        // getTxtRecord() 至今是 hidden API(API 36 android.jar 已无此符号),
        // 公有读取走 getAttributes()(API 29 起公开,Map<String, ByteArray>)。
        info.attributes.forEach { (k, v) -> txt[k] = String(v, Charsets.UTF_8) }
        val host = info.host?.hostAddress ?: ""
        emit(
            mapOf(
                "event" to "found",
                "name" to name,
                "host" to host,
                "port" to (info.port.takeIf { it != 0 } ?: DEFAULT_PORT),
                "txt" to txt,
            ),
        )
        if (host.isEmpty()) {
            Log.w(TAG, "resolveService($name) 未返回 host")
        }
    }

    private fun emit(payload: Map<String, Any?>) {
        sink?.success(payload)
    }
}
