package com.aha.zpill.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.aha.zpill.log.NativeLog
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * ZPill USB 主机通道(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/usb/usb_host.dart(v2 字节管道):
 * - bulkRead(maxLen, timeoutMs):单次读、短读合法,native 不做容器重组
 *   (容器头解析/按长度补齐在 Dart 的 UsbPtpTransport;GetObject 25.6MB
 *   单容器不能整体过通道驻留内存);
 * - 窗口内无数据 → PlatformException code 'usb_timeout'(Dart 映射
 *   TimeoutException);
 * - bulkOut:native 内部 16KB 分块循环写;
 * - drainIn:中止/超时事务的有界冲刷 —— 吸干 bulk IN 残余字节(相机
 *   还在吐的数据相位尾巴 + 超读暂存),下一事务不从错位字节开始
 *   (Dart 的 UsbPtpTransport 在事务异常收场时调用,见 drainIn 头注);
 * - interrupt 事件走 EventChannel,完整事件容器(≤64B)由本文件重组
 *   (12B 头 + u32 长度驱动)。
 *
 * Android API 要点(UsbDeviceConnection,编译期 minSdk 29,真机待验证):
 * - bulkTransfer 同步阻塞:MethodChannel 回调在主线程,全部 bulk 收发
 *   投递到单线程 ExecutorService,结果经主线程 Handler 回传;
 * - AOSP 实现对 timeout 非零的 bulkTransfer 有 16384B 单次上限 →
 *   bulkRead 内部 16KB 分块循环组装,一次通道调用读满 maxLen
 *   (Dart 1MB 流块不再退化为逐 16KB 通道往返;详见 bulkRead 头注);
 *   timeout=0(无限)路径不受此限,interrupt 轮询 64B 缓冲无影响;
 * - bulkTransfer 失败统一返回负值,**无法区分 STALL 与超时**(nico 亦无
 *   判别手法,负值无条件清 halt 重试一次):写路径每 16KB 块清 halt 重试
 *   一次(ohos 实证,STALL 在相机侧是流控不是错误);读路径空手负值同样
 *   清 halt 原地重读一次 —— STALL 即时失败、超时吃满窗口,窗口尚有
 *   余量才值得重试;重试仍败按契约上报(usb_timeout/usb_error);
 * - 无 clearHalt API:走 controlTransfer(0x02, 0x01, 0, addr, null, 0, 0)
 *   手工 CLEAR_FEATURE(ENDPOINT_HALT)。open 成功后对两个 bulk 端点
 *   各做一次(上轮失败会在设备侧留下脏状态:OUT data toggle 停在
 *   DATA1,重新 claim 不复位 → 后续写全被丢;ohos 真机实证);
 * - 权限:hasPermission → 否则 requestPermission(PendingIntent)异步等
 *   系统弹框(PendingIntent 需 FLAG_MUTABLE,API 31+;context-registered
 *   receiver 需 RECEIVER_NOT_EXPORTED,API 33+)。
 *
 * 相机侧(Zf,ohos 真机实测,代码不写死,按描述符枚举):
 * STI 接口 class 6,bulk IN 0x81 / bulk OUT 0x02 / interrupt IN 0x83,
 * interrupt wMaxPacketSize=8(事件 16B 会跨包,native 重组处理)。
 */
class UsbHostPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val TAG = "UsbHostPlugin"
        private const val CHANNEL = "zpill/usb"
        private const val EVENTS_CHANNEL = "zpill/usb/events"

        /// 尼康 USB Vendor ID(USB-IF 分配)。
        private const val NIKON_VENDOR_ID = 0x04B0

        /// USB Still Image class(PTP)。STI 接口按描述符枚举,不写死接口号。
        private const val USB_CLASS_STILL_IMAGE = 6

        /// CLEAR_FEATURE 控制请求(bmRequestType 0x02 = OUT|standard|endpoint)。
        private const val USB_REQUEST_TARGET_ENDPOINT = 0x02
        private const val USB_REQUEST_CLEAR_FEATURE = 0x01
        private const val ENDPOINT_HALT = 0x0000

        /// bulkOut 内部分块。
        private const val BULK_OUT_CHUNK_BYTES = 16 * 1024
        /// bulkOut 整体超时(命令/数据出相位,相机不会长时间拒收)。
        private const val BULK_OUT_TIMEOUT_MS = 5000

        /// bulk IN 单次读下限与有限超时的单次上限(见类头注 AOSP 16KB 限制)。
        private const val BULK_IN_MIN_READ_BYTES = 16 * 1024

        /// interrupt 事件缓冲:PTP 事件容器 ≤64B(Zf 实测 12/16B)。
        private const val INTERRUPT_BUF_BYTES = 64

        /// drainIn 单轮静默窗:一轮 300ms 内无数据即认为吸干(nico 同口径)。
        private const val DRAIN_QUIET_MS = 300

        /// drainIn 轮数上限:数据持续到达也最多吸 32 轮(有界,别无限等;
        /// 最坏 ≈9.6s 静默耗尽,单轮 ≤16KB 受 AOSP 有限超时上限约束)。
        private const val DRAIN_MAX_ROUNDS = 32
    }

    /** 打开会话:连接、接口与三个端点。 */
    private class UsbSession(
        val connection: UsbDeviceConnection,
        val iface: UsbInterface,
        val bulkIn: UsbEndpoint,
        val bulkOut: UsbEndpoint,
        val interruptIn: UsbEndpoint?,
    )

    /**
     * interrupt IN 字节流 → PTP 事件容器 重组器。
     * 12B 头:u32 总长(含头)+ u16 type + u16 code + u32 txid;
     * 长度字段驱动补齐,凑齐一个完整容器就上抛一个。
     * 畸形(长度 <12 或 >64)时丢弃缓冲重新同步(事件流允许丢帧,不断流)。
     * push 在 interrupt 轮询线程、reset 在主线程 → 方法级同步。
     */
    private class InterruptAssembler {
        private var pending = ByteArray(0)

        @Synchronized
        fun reset() {
            pending = ByteArray(0)
        }

        @Synchronized
        fun push(bytes: ByteArray, emit: (ByteArray) -> Unit) {
            pending = pending + bytes
            while (pending.size >= 12) {
                val len = u32le(0)
                if (len < 12 || len > 64) {
                    Log.w(TAG, "事件容器长度畸形 len=$len,丢弃缓冲重新同步")
                    pending = ByteArray(0)
                    return
                }
                if (pending.size < len) {
                    break // 头已到,体未齐,等下一包
                }
                emit(pending.copyOf(len))
                pending = pending.copyOfRange(len, pending.size)
            }
        }

        private fun u32le(offset: Int): Int =
            pending[offset].toInt() and 0xFF or
                (pending[offset + 1].toInt() and 0xFF shl 8) or
                (pending[offset + 2].toInt() and 0xFF shl 16) or
                (pending[offset + 3].toInt() and 0xFF shl 24)
    }

    private var channel: MethodChannel? = null
    private var events: EventChannel? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null
    @Volatile
    private var session: UsbSession? = null
    @Volatile
    private var pollStopped = true
    /// open 世代计数:teardown 递增;异步等待(权限弹框/executor 排队)回来
    /// 时代数不符 → usb_stale,防止旧链路管道漏关或污染新会话。
    @Volatile
    private var openGeneration = 0

    private val assembler = InterruptAssembler()
    private val lock = Any()

    /// bulk IN 超读余量(≥maxLen 之外的突发字节),下次 bulkRead 先掏这里。
    private var bulkInLeftover = ByteArray(0)

    private lateinit var appContext: Context
    private lateinit var usbManager: UsbManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var permissionReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        usbManager = appContext.getSystemService(Context.USB_SERVICE) as UsbManager
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
        pendingPermissionReceiverTeardown()
        teardownSession()
        ioExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "listCameras" -> listCameras(result)
            "open" -> open(call.argument<String>("identifier") ?: "", result)
            "bulkOut" -> bulkOut(call.argument<ByteArray>("bytes") ?: ByteArray(0), result)
            "bulkRead" -> bulkRead(
                call.argument<Int>("maxLen") ?: 0,
                call.argument<Int>("timeoutMs") ?: 0,
                result,
            )
            "drainIn" -> drainIn(result)
            "close" -> {
                teardownSession()
                postSuccess(result, null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // 惰性轮询:只有 Dart 订阅了事件流才碰 interrupt 端点,
        // 避免与 bulk 主线并发传输的不确定性(主线 P0 不订阅,零风险)。
        startInterruptPoll()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        pollStopped = true
    }

    /// 枚举尼康相机(VID 0x04B0);未插入返回空表(枚举不需要权限)。
    private fun listCameras(result: Result) {
        try {
            val out = usbManager.deviceList.values
                .filter { it.vendorId == NIKON_VENDOR_ID }
                .map {
                    mapOf(
                        "vendorId" to it.vendorId,
                        "productId" to it.productId,
                        "identifier" to it.deviceName,
                    )
                }
            postSuccess(result, out)
        } catch (e: Exception) {
            postError(result, "usb_error", "deviceList: $e")
        }
    }

    /// 打开并独占 Still Image 接口:权限(系统弹框)→ openDevice →
    /// claimInterface(STI 按描述符枚举)→ 端点按 type/direction 分拣。
    private fun open(identifier: String, result: Result) {
        teardownSession()
        val gen = openGeneration
        val device = try {
            usbManager.deviceList.values.firstOrNull { it.deviceName == identifier }
        } catch (e: Exception) {
            postError(result, "usb_error", "deviceList: $e")
            return
        }
        if (device == null) {
            postError(result, "usb_error", "device not found: $identifier")
            return
        }
        if (usbManager.hasPermission(device)) {
            openDevice(device, gen, result)
        } else {
            requestPermissionThenOpen(device, gen, result)
        }
    }

    /// 系统授权弹框:requestPermission 经 PendingIntent 回广播;授权与否
    /// 均只应答一次。用户不回应 → 无广播,Dart 看门狗兜底(ohos 同语义)。
    private fun requestPermissionThenOpen(device: UsbDevice, gen: Int, result: Result) {
        val action = appContext.packageName + ".USB_PERMISSION"
        pendingPermissionReceiverTeardown()
        val intent = Intent(action)
        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val pi = PendingIntent.getBroadcast(appContext, 0, intent, piFlags)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != action) return
                pendingPermissionReceiverTeardown()
                val grantedDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (!granted || grantedDevice?.deviceName != device.deviceName) {
                    postError(result, "usb_denied", "用户未授权 USB 访问")
                } else if (gen != openGeneration) {
                    postError(result, "usb_stale", "会话已轮换,授权结果丢弃")
                } else {
                    openDevice(device, gen, result)
                }
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(receiver, filter)
        }
        permissionReceiver = receiver
        usbManager.requestPermission(device, pi)
    }

    private fun pendingPermissionReceiverTeardown() {
        permissionReceiver?.let {
            try {
                appContext.unregisterReceiver(it)
            } catch (_: Exception) {
                // 未注册或已注销,忽略
            }
        }
        permissionReceiver = null
    }

    /// 设备 I/O 在 executor 上做(openDevice 里的 open/claim/控制传输都
    /// 是阻塞调用,不得占主线程)。
    private fun openDevice(device: UsbDevice, gen: Int, result: Result) {
        ioExecutor.execute {
            if (gen != openGeneration) {
                postError(result, "usb_stale", "会话已轮换,打开结果丢弃")
                return@execute
            }
            try {
                // STI 接口:优先 class 6;后备:含 bulk IN/OUT 双端点的接口。
                var iface: UsbInterface? = null
                var fallback: UsbInterface? = null
                for (i in 0 until device.interfaceCount) {
                    val candidate = device.getInterface(i)
                    if (candidate.interfaceClass == USB_CLASS_STILL_IMAGE) {
                        iface = candidate
                        break
                    }
                    if (fallback == null) {
                        var hasBulkIn = false
                        var hasBulkOut = false
                        for (j in 0 until candidate.endpointCount) {
                            val ep = candidate.getEndpoint(j)
                            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                                ep.direction == UsbConstants.USB_DIR_IN
                            ) {
                                hasBulkIn = true
                            } else if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                                ep.direction == UsbConstants.USB_DIR_OUT
                            ) {
                                hasBulkOut = true
                            }
                        }
                        if (hasBulkIn && hasBulkOut) {
                            fallback = candidate
                        }
                    }
                }
                val chosen = iface ?: fallback
                if (chosen == null) {
                    postError(result, "usb_error", "Still Image 接口未找到")
                    return@execute
                }

                var bulkIn: UsbEndpoint? = null
                var bulkOut: UsbEndpoint? = null
                var interruptIn: UsbEndpoint? = null
                for (j in 0 until chosen.endpointCount) {
                    val ep = chosen.getEndpoint(j)
                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                        ep.direction == UsbConstants.USB_DIR_IN
                    ) {
                        bulkIn = ep
                    } else if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                        ep.direction == UsbConstants.USB_DIR_OUT
                    ) {
                        bulkOut = ep
                    } else if (ep.type == UsbConstants.USB_ENDPOINT_XFER_INT &&
                        ep.direction == UsbConstants.USB_DIR_IN
                    ) {
                        interruptIn = ep
                    }
                }
                if (bulkIn == null || bulkOut == null) {
                    postError(result, "usb_error", "bulk IN/OUT 端点未找到")
                    return@execute
                }

                val connection = usbManager.openDevice(device)
                if (!connection.claimInterface(chosen, true)) {
                    try {
                        connection.close()
                    } catch (e: Exception) {
                        Log.w(TAG, "close after claim failure: $e")
                    }
                    postError(result, "usb_error", "claimInterface 失败")
                    return@execute
                }

                Log.i(
                    TAG,
                    "open: iface=${chosen.id} bulkIn=0x${bulkIn.address.toString(16)} " +
                        "bulkOut=0x${bulkOut.address.toString(16)}" +
                        if (interruptIn != null) " interruptIn=0x${interruptIn.address.toString(16)}" else " interruptIn=无",
                )
                val s = UsbSession(connection, chosen, bulkIn, bulkOut, interruptIn)
                // 上轮失败会在设备侧留下脏状态(OUT toggle 停在 DATA1 → 后续写全被
                // 丢;IN 端点可能还压着未读残数据)。USB 2.0:
                // ClearFeature(ENDPOINT_HALT) 无条件把两端 data toggle 重置回
                // DATA0。clearHalt 尽力而为,失败不阻断 open。
                clearHalt(s, bulkIn.address)
                clearHalt(s, bulkOut.address)

                if (gen != openGeneration) {
                    // 等待 I/O 期间会话被轮换:刚拿到的连接立即关掉
                    try {
                        connection.releaseInterface(chosen)
                        connection.close()
                    } catch (e: Exception) {
                        Log.w(TAG, "close after rotation: $e")
                    }
                    postError(result, "usb_stale", "会话已轮换,打开结果丢弃")
                    return@execute
                }
                session = s
                // 先订阅后连接的场景:打开成功时若事件流已在监听,这里补启动轮询
                if (sink != null) {
                    startInterruptPoll()
                }
                postSuccess(result, null)
            } catch (e: Exception) {
                postError(result, "usb_error", "open: $e")
            }
        }
    }

    /// bulk OUT:native 内部 16KB 分块;负值时 CLEAR_FEATURE 后重试一次
    /// (相机以 STALL 表达流控是正常现象,不得当错误上抛)。
    private fun bulkOut(bytes: ByteArray, result: Result) {
        val s = session
        if (s == null) {
            postError(result, "usb_closed", "会话未打开")
            return
        }
        ioExecutor.execute {
            try {
                var off = 0
                while (off < bytes.size) {
                    val end = min(off + BULK_OUT_CHUNK_BYTES, bytes.size)
                    val chunk = bytes.copyOfRange(off, end)
                    var n = s.connection.bulkTransfer(s.bulkOut, chunk, chunk.size, BULK_OUT_TIMEOUT_MS)
                    if (n < 0) {
                        Log.w(TAG, "bulkOut ret=$n,CLEAR_FEATURE 后重试")
                        clearHalt(s, s.bulkOut.address)
                        n = s.connection.bulkTransfer(s.bulkOut, chunk, chunk.size, BULK_OUT_TIMEOUT_MS)
                        if (n < 0) {
                            NativeLog.e("usb", "bulkOut 失败:ret=$n(共 ${bytes.size}B,已写 ${off}B)")
                            postError(result, "usb_error", "bulkTransfer out ret=$n")
                            return@execute
                        }
                    }
                    off = end
                }
                // 会话轮换守卫:等待期间 teardown/重连会让 s 的连接失效。
                // 对应的 Dart 调用早已被看门狗判超时遗弃;应答只为释放通道。
                if (session !== s) {
                    postError(result, "usb_stale", "会话已轮换,旧链路写结果丢弃")
                    return@execute
                }
                postSuccess(result, null)
            } catch (e: Exception) {
                postError(result, "usb_error", "bulkOut: $e")
            }
        }
    }

    /// bulk IN:单次通道调用、短读合法;≥1 字节成功,否则按契约抛
    /// usb_timeout/usb_error。
    ///
    /// AOSP 有限超时 bulkTransfer 单次 ≤16KB → native 内部 16KB 分块循环
    /// 组装:一次通道调用最多读满 maxLen(1MB 块 = 64 次 syscall,省掉
    /// 等量通道往返)。分块规则:
    /// - 有限超时:每块 ≤16KB,单块超时 = 剩余窗口(绝不为 0),总窗口
    ///   耗尽即止(与 Dart 看门狗的上限一致);无限超时:整块一次读
    ///   (timeout=0 路径不受 16KB 限制,语义与旧单调用实现一致);
    /// - 短读(n<callLen)= 相机突发结束 → 立即交付;满块继续;
    /// - ZLB(n==0):已见数据 = 传输边界 → 交付;未见数据 = 耗窗口续等
    ///   (ohos 真机实证存在 ZLB-先于-数据);
    /// - n<0:已有部分数据则交付短读(数据是真实的,不丢);空手负值
    ///   清 halt(ENDPOINT_HALT)后原地重读一次(STALL=相机流控,即时
    ///   失败;超时=窗口耗尽,不再重试),仍败按超时/错误上报;
    /// - 容器恰为 16KB 整数倍时靠尾随 ZLB 收尾(ZLB 在传输结束后即刻
    ///   到达),极端时序下最多等到窗口耗尽才交付,数据不丢(待真机核对)。
    ///
    /// 小请求(maxLen<16KB)仍单次 16KB 超读:超出 maxLen 的字节暂存
    /// leftover,下次调用先掏(对 Dart 是普通短读流),命令相位的多次
    /// 小读可被一次超读吸收。
    private fun bulkRead(maxLen: Int, timeoutMs: Int, result: Result) {
        val s = session
        if (s == null) {
            postError(result, "usb_closed", "会话未打开")
            return
        }
        if (maxLen <= 0) {
            postError(result, "usb_error", "bulkRead maxLen=$maxLen 非正")
            return
        }
        ioExecutor.execute {
            try {
                synchronized(lock) {
                    if (bulkInLeftover.isNotEmpty()) {
                        val take = min(maxLen, bulkInLeftover.size)
                        val out = bulkInLeftover.copyOf(take)
                        bulkInLeftover = bulkInLeftover.copyOfRange(take, bulkInLeftover.size)
                        postSuccess(result, out)
                        return@execute
                    }
                }
                val buffer = ByteArray(max(maxLen, BULK_IN_MIN_READ_BYTES))
                // 后续分块先读草稿区再拼入 bulkTransfer 无偏移重载
                // (minSdk 29,API 33 的 offset 重载不可无条件用)。
                val scratch = ByteArray(BULK_IN_MIN_READ_BYTES)
                val start = SystemClock.elapsedRealtime()
                val deadline = if (timeoutMs > 0) start + timeoutMs else Long.MAX_VALUE
                var filled = 0
                var failed = false
                var haltRetried = false
                loop@ while (filled < buffer.size) {
                    val room = buffer.size - filled
                    val callLen: Int
                    val callTimeout: Int
                    if (timeoutMs <= 0) {
                        callLen = room
                        callTimeout = 0
                    } else {
                        val restMs = (deadline - SystemClock.elapsedRealtime()).toInt()
                        if (restMs <= 0) {
                            break@loop // 窗口耗尽:有数据交付短读,无数据走超时
                        }
                        callLen = min(room, BULK_IN_MIN_READ_BYTES)
                        callTimeout = max(1, restMs)
                    }
                    val n = if (filled == 0) {
                        s.connection.bulkTransfer(s.bulkIn, buffer, callLen, callTimeout)
                    } else {
                        val got = s.connection.bulkTransfer(s.bulkIn, scratch, callLen, callTimeout)
                        if (got > 0) {
                            System.arraycopy(scratch, 0, buffer, filled, got)
                        }
                        got
                    }
                    when {
                        n > 0 -> {
                            filled += n
                            if (n < callLen) break@loop // 短读 = 突发结束
                        }
                        n == 0 -> {
                            if (filled > 0) break@loop // ZLB:边界,交付
                            // 未见数据的 ZLB:继续耗窗口等真数据
                        }
                        else -> {
                            // 空手负值:清 halt 后原地重读一次(nico/libgphoto2
                            // 口径 —— Android 负值分不清 STALL 与超时,但
                            // STALL 即时失败、超时吃满窗口,窗口尚有余量才
                            // 值得重试)。有限窗口已耗尽 = 真超时,不再重试。
                            if (filled == 0 && !haltRetried &&
                                (timeoutMs <= 0 ||
                                    deadline - SystemClock.elapsedRealtime() > 0)
                            ) {
                                haltRetried = true
                                Log.w(TAG, "bulkRead ret=$n,CLEAR_FEATURE 后原地重读")
                                clearHalt(s, s.bulkIn.address)
                                continue@loop
                            }
                            if (filled == 0) failed = true
                            break@loop // 部分数据优先交付
                        }
                    }
                }
                // 会话轮换守卫(关键):等待期间 teardown/重连会让 s 的连接失效,
                // 而晚到的数据绝不能进 bulkInLeftover —— leftover 是共享字段,
                // 旧链路的字节会污染**新会话**的读流。对应的 Dart 调用早已被
                // 看门狗判超时遗弃;应答只为释放通道。
                if (session !== s) {
                    postError(result, "usb_stale", "会话已轮换,旧链路读结果丢弃")
                    return@execute
                }
                if (filled > 0) {
                    if (filled > maxLen) {
                        synchronized(lock) {
                            bulkInLeftover = buffer.copyOfRange(maxLen, filled)
                        }
                        postSuccess(result, buffer.copyOf(maxLen))
                    } else {
                        postSuccess(result, buffer.copyOf(filled))
                    }
                } else if (failed) {
                    NativeLog.e("usb", "bulkRead 失败:负值返回(max=${maxLen}B,窗=${timeoutMs}ms)")
                    if (timeoutMs > 0) {
                        // 窗口内无数据(含清 halt 重读仍败):对齐 Dart 的
                        // TimeoutException 语义 —— 可恢复的普通失败,不断链。
                        postError(result, "usb_timeout", "bulkTransfer 负值返回(有限超时窗口内无数据)")
                    } else {
                        postError(result, "usb_error", "bulkTransfer 负值返回(无限等待失败)")
                    }
                } else {
                    postError(result, "usb_timeout", "bulkRead ${timeoutMs}ms 窗口内无数据")
                }
            } catch (e: Exception) {
                NativeLog.e("usb", "bulkRead 异常:$e")
                postError(result, "usb_error", "bulkRead: $e")
            }
        }
    }

    /// bulk IN 冲刷:中止/超时事务的残余字节吸干,下一事务不从错位
    /// 字节开始(nico PtpTransport.drainIn 同款)。调用方是 Dart 的
    /// UsbPtpTransport 在事务异常收场时于 execute() 内调用 —— 冲刷
    /// 发生在 PtpSession 串行门持有期内,与下一事务天然串行不交错。
    ///
    /// 残余两处来源都要收:
    /// - bulkRead 超读暂存(bulkInLeftover)—— 属被中止事务,先丢;
    /// - 相机仍在吐的数据相位字节 —— 单轮 ≤16KB(AOSP 有限超时上限)
    ///   × 300ms 静默窗,静默一轮即吸干;连续 [DRAIN_MAX_ROUNDS] 轮
    ///   上限保证有界(数据持续到达也不无限等)。
    /// 单轮容量 16KB×32 轮 = 512KB(nico 为 64KB×32;残余超过此量
    /// 的极端只能靠上层断链重连,大档取消的排空走 Dart 整档收块路线,
    /// 不经过这里)。返回冲刷字节数(Dart 契约为 void,仅日志价值)。
    private fun drainIn(result: Result) {
        val s = session
        if (s == null) {
            postError(result, "usb_closed", "会话未打开")
            return
        }
        ioExecutor.execute {
            try {
                synchronized(lock) {
                    bulkInLeftover = ByteArray(0)
                }
                val buf = ByteArray(BULK_IN_MIN_READ_BYTES)
                var drained = 0L
                var rounds = 0
                while (rounds < DRAIN_MAX_ROUNDS) {
                    rounds++
                    val n = s.connection.bulkTransfer(s.bulkIn, buf, buf.size, DRAIN_QUIET_MS)
                    if (n < 0) break // 静默窗内无数据:已吸干
                    drained += n // n==0(ZLB)也耗一轮,继续吸
                }
                if (drained > 0) {
                    Log.i(TAG, "drainIn 吸干 ${drained}B(${rounds} 轮)")
                }
                // 会话轮换守卫:与 bulkRead 同款 —— 旧链路的冲刷结果只
                // 释放通道应答,不污染新会话。
                if (session !== s) {
                    postError(result, "usb_stale", "会话已轮换,冲刷结果丢弃")
                    return@execute
                }
                postSuccess(result, drained)
            } catch (e: Exception) {
                NativeLog.e("usb", "drainIn 异常:$e")
                postError(result, "usb_error", "drainIn: $e")
            }
        }
    }

    /// STALL 恢复/端点复位:手工 CLEAR_FEATURE 控制请求(Android 无
    /// clearHalt API)。尽力而为,失败只记日志。
    private fun clearHalt(s: UsbSession, endpointAddr: Int) {
        try {
            val rc = s.connection.controlTransfer(
                USB_REQUEST_TARGET_ENDPOINT,
                USB_REQUEST_CLEAR_FEATURE,
                ENDPOINT_HALT,
                endpointAddr,
                null,
                0,
                0,
            )
            if (rc < 0) {
                Log.w(TAG, "clearHalt(0x${endpointAddr.toString(16)}) rc=$rc")
            }
        } catch (e: Exception) {
            Log.w(TAG, "clearHalt(0x${endpointAddr.toString(16)}): $e")
        }
    }

    /// interrupt 轮询(仅在 Dart 订阅事件流后启动)。
    /// timeout=0 无限等待,避免空转;连接关闭后挂着的传输会失败返回。
    /// @Synchronized:openDevice(executor)与 onListen(主线程)都可能
    /// 触发,防双轮询竞态。
    @Synchronized
    private fun startInterruptPoll() {
        val s = session ?: return
        val endpoint = s.interruptIn ?: return
        if (!pollStopped) return
        pollStopped = false
        Thread {
            Log.i(TAG, "interrupt 轮询启动")
            val buf = ByteArray(INTERRUPT_BUF_BYTES)
            while (!pollStopped && session === s && sink != null) {
                val n = try {
                    s.connection.bulkTransfer(endpoint, buf, buf.size, 0)
                } catch (e: Exception) {
                    Log.w(TAG, "interrupt 读异常: $e")
                    -1
                }
                if (pollStopped || session !== s) {
                    break
                }
                if (n > 0) {
                    assembler.push(buf.copyOf(n)) { frame ->
                        // EventSink 只能在主线程调
                        mainHandler.post { sink?.success(frame) }
                    }
                } else if (n < 0) {
                    // 无限等待下仍失败:连接已坏或端点不接受该传输类型。
                    Log.w(TAG, "interrupt 读失败 ret=$n,停止轮询(事件流不可用,主线不受影响)")
                    break
                }
                // n == 0:ZLB 空包,继续
            }
            Log.i(TAG, "interrupt 轮询退出")
        }.apply {
            name = "zpill-usb-interrupt"
            start()
        }
    }

    /// 关闭会话(幂等):停轮询 → release → close。
    private fun teardownSession() {
        openGeneration++
        pollStopped = true
        val s = session
        session = null
        assembler.reset()
        synchronized(lock) {
            bulkInLeftover = ByteArray(0)
        }
        if (s == null) return
        try {
            s.connection.releaseInterface(s.iface)
        } catch (e: Exception) {
            Log.w(TAG, "releaseInterface: $e")
        }
        try {
            s.connection.close()
        } catch (e: Exception) {
            Log.w(TAG, "close: $e")
        }
    }

    /// 通道结果一律经主线程 Handler 回传(executor/广播回调线程不准直接调)。
    private fun postSuccess(result: Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }
}
