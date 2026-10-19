package com.aha.nikonpill.ble

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.aha.nikonpill.log.NativeLog
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

import java.util.UUID

/**
 * NikonPill BLE 裸桥(Android 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/ble_scanner.dart(BleHost):
 * MethodChannel `nikonpill/ble` + EventChannel `nikonpill/ble/events`。
 * 协议逻辑(配对握手/GEO/TIME 载荷)全在 Dart(lib/core/ble/),本桥
 * 只做扫描/连接/GATT 搬运,零 Nikon 方言知识 —— 唯一例外:bondDevice
 * (程序化经典蓝牙绑定;Android createBond 公开 API 可为,首配注册用,
 * ohos 同款语义:iOS 无此路只能引导系统设置页)。
 *
 * 事件载荷(Map,与 iOS/ohos BlePlugin 同形):state / discovered /
 * connected(附全特征表与 MTU)/ disconnected / notify / error / bond。
 *
 * Android API 要点(对齐 ohos 实证方言):
 * - 扫描 = BluetoothLeScanner.startScan(LOW_LATENCY);厂商数据
 *   getManufacturerSpecificData(0x0399) **不含**两字节 ID 前缀,对外
 *   补齐 [0x99,0x03](与 iOS 同形);设备名优先取广播
 *   ScanRecord.getDeviceName(免 CONNECT 权限),缓砖 BluetoothDevice.name
 * - GATT = device.connectGatt(ctx, false, cb, TRANSPORT_LE);连上先
 *   requestMtu(517)(MTU 未回 5s 看门狗强发发现),onServicesDiscovered
 *   空表/缺 PAIR 重试 ×2 间隔 2s(链路未稳,D5600/Zf 实证同 ohos)
 * - notify/indicate 都须写 CCCD 0x2902(notify 0x0100/indicate 0x0200,
 *   setCharacteristicNotification 只开本地侧);GATT 单飞行纪律 = 读写
 *   描述符全走一条 op 队列串行
 * - 绑定 = BluetoothDevice.createBond(BLE MAC 即经典 MAC,免经典发现,
 *   与 ohos 不同);系统弹窗确认后 ACTION_BOND_STATE_CHANGED 收口
 * - 权限:API 31+ 运行时 BLUETOOTH_SCAN + BLUETOOTH_CONNECT;
 *   API 29/30 走 ACCESS_FINE_LOCATION(Manifest 已有)+ 老蓝牙权限
 */
class BlePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        private const val TAG = "BlePlugin"
        private const val CHANNEL = "nikonpill/ble"
        private const val EVENTS = "nikonpill/ble/events"
        private const val NIKON_COMPANY_ID = 0x0399
        private const val PAIR_CHAR = "00002000-3dd4-4255-8d62-6dc7b9bd5561"
        private const val CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
        private const val REQUEST_CODE = 8001
        private const val MTU_TARGET = 517
        private const val MTU_WATCHDOG_MS = 5000L
        private const val DISCOVERY_RETRY_MS = 2000L
        private const val DISCOVERY_RETRY_MAX = 2
        private const val BOND_TIMEOUT_MS = 20000L
    }

    private enum class OpKind { WRITE_CHAR, WRITE_DESC, READ }

    /** 单笔在途 GATT 操作(队列串行;回调解锁后取下一笔)。 */
    private class PendingOp(
        val kind: OpKind,
        val uuid: String,
        val data: ByteArray? = null,
        val withoutResponse: Boolean = false,
        val result: MethodChannel.Result? = null,
    )

    private class ScanHit(
        val name: String,
        val uuid: String,
        val rssi: Int,
        val mfg: ByteArray,
    )

    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingPermission: (() -> Unit)? = null
    private var permissionListener: PluginRegistry.RequestPermissionsResultListener? = null

    // 扫描
    private var scanHits = LinkedHashMap<String, ScanHit>()
    private var scanFilterDeviceId: Int? = null
    private var scanResult: MethodChannel.Result? = null

    // 连接 / GATT
    private var gatt: BluetoothGatt? = null
    private var deviceId = ""
    private val charMap = HashMap<String, BluetoothGattCharacteristic>()
    private val propsMap = HashMap<String, String>()
    private var mtu = 20
    private var pendingConnect: MethodChannel.Result? = null
    private var discoveryRetries = 0
    private var discoveryInFlight = false
    private var discoveryDone = false
    private val opQueue = ArrayDeque<PendingOp>()
    private var opBusy = false

    // 绑定(经典蓝牙)
    private var pendingBond: MethodChannel.Result? = null

    private val adapter: BluetoothAdapter?
        get() = (context?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> emit(mapOf("type" to "state", "state" to "poweredOn"))
                BluetoothAdapter.STATE_TURNING_ON -> emit(mapOf("type" to "state", "state" to "turningOn"))
                BluetoothAdapter.STATE_TURNING_OFF -> emit(mapOf("type" to "state", "state" to "turningOff"))
                BluetoothAdapter.STATE_OFF -> {
                    emit(mapOf("type" to "state", "state" to "poweredOff"))
                    // 蓝牙关闭连底层断开回调都不保证:主动清干净
                    if (gatt != null) onDisconnectedLocal()
                }
            }
        }
    }

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val dev = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            } ?: return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            emit(
                mapOf(
                    "type" to "bond", "state" to state,
                    "uuid" to dev.address, "name" to (safeName(dev) ?: ""),
                )
            )
            if (dev.address != deviceId) return
            when (state) {
                BluetoothDevice.BOND_BONDED -> settleBond(true, null)
                BluetoothDevice.BOND_NONE -> settleBond(false, "配对被拒绝或失败")
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @Deprecated("Deprecated in Java")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    discoveryRetries = 0
                    discoveryDone = false
                    try {
                        g.requestMtu(MTU_TARGET)
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "requestMtu: $e")
                    }
                    // MTU 协商兜底:5s 没等到 onMtuChanged 也强行发现(ohos 同款)
                    mainHandler.postDelayed({
                        if (g === this@BlePlugin.gatt && !discoveryDone && !discoveryInFlight) {
                            discoverServices()
                        }
                    }, MTU_WATCHDOG_MS)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    NativeLog.w("ble", "BLE 断连:status=$status($deviceId)")
                    onDisconnectedLocal()
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) this@BlePlugin.mtu = mtu
                discoverServices()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                discoveryInFlight = false
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    settleConnect("discoveryFailed", "服务发现失败(status=$status)")
                    return@post
                }
                buildServiceTable()
                if (!charMap.containsKey(PAIR_CHAR)) {
                    // 空表/缺 PAIR = 链路未稳(D5600/Zf 实证)→ 重试后再判
                    if (discoveryRetries < DISCOVERY_RETRY_MAX) {
                        discoveryRetries++
                        android.util.Log.w(TAG, "getServices 空表/缺 PAIR — 重试($discoveryRetries/$DISCOVERY_RETRY_MAX)")
                        mainHandler.postDelayed({ discoverServices() }, DISCOVERY_RETRY_MS)
                        return@post
                    }
                    settleConnect("discoveryFailed", "未发现 LSS 服务(链路未稳或非尼康机身)")
                    return@post
                }
                discoveryDone = true
                val chars = HashMap<String, String>(propsMap)
                emit(
                    mapOf(
                        "type" to "connected", "uuid" to deviceId,
                        "characteristics" to chars, "mtu" to mtu,
                    )
                )
                settleConnect(null, null)
            }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                val value = if (status == BluetoothGatt.GATT_SUCCESS) {
                    characteristic.value
                } else {
                    null
                }
                settleOp(status, value)
            }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                settleOp(status, null)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                settleOp(status, null)
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            // API 33+:通知走新签名;旧签名在本机不会触发
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                emit(
                    mapOf(
                        "type" to "notify",
                        "uuid" to characteristic.uuid.toString(),
                        "data" to value,
                    )
                )
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            // API < 33:通知走旧签名,值取 characteristic.value
            mainHandler.post {
                if (g !== this@BlePlugin.gatt) return@post
                emit(
                    mapOf(
                        "type" to "notify",
                        "uuid" to characteristic.uuid.toString(),
                        "data" to characteristic.value,
                    )
                )
            }
        }
    }

    // ------------------------------------------------------------------
    // FlutterPlugin / ActivityAware
    // ------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        EventChannel(binding.binaryMessenger, EVENTS).setStreamHandler(this)
        try {
            context?.registerReceiver(stateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        } catch (e: Exception) {
            android.util.Log.w(TAG, "register stateReceiver: $e")
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context?.registerReceiver(
                    bondReceiver,
                    IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
                    Context.RECEIVER_EXPORTED,
                )
            } else {
                context?.registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "register bondReceiver: $e")
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        sink = null
        try {
            context?.unregisterReceiver(stateReceiver)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "unregister stateReceiver: $e")
        }
        try {
            context?.unregisterReceiver(bondReceiver)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "unregister bondReceiver: $e")
        }
        mainHandler.removeCallbacksAndMessages(null)
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        permissionListener =
            PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
                if (requestCode != REQUEST_CODE) {
                    false
                } else {
                    permissionListener = null
                    val pending = pendingPermission
                    pendingPermission = null
                    if (pending != null) {
                        val granted = blePermissions().all {
                            context?.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
                        }
                        if (granted) {
                            pending()
                        } else {
                            emit(
                                mapOf(
                                    "type" to "error", "code" to "permissionDenied",
                                    "message" to "蓝牙权限未授权", "uuid" to "",
                                )
                            )
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

    // ------------------------------------------------------------------
    // MethodChannel / EventChannel
    // ------------------------------------------------------------------

    override fun onListen(args: Any?, events: EventChannel.EventSink?) {
        sink = events
        emit(mapOf("type" to "state", "state" to currentState()))
    }

    override fun onCancel(args: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.i(TAG, "method=${call.method}")
        when (call.method) {
            "isAvailable" -> result.success(adapter?.isEnabled == true)
            "scan" -> ensurePermissions { startScan(call.argument<Int>("seconds") ?: 10, null, result) }
            "scanForDeviceId" -> ensurePermissions {
                startScan(
                    call.argument<Int>("seconds") ?: 10,
                    call.argument<Int>("deviceId"),
                    result,
                )
            }
            "stopScan" -> {
                stopScanNative()
                result.success(null)
            }
            "connectPaired" -> {
                val uuid = call.arguments as? String ?: ""
                if (uuid.isEmpty()) {
                    result.error("badArgs", "connectPaired 须传设备标识", null)
                } else {
                    ensurePermissions { connectPaired(uuid, result) }
                }
            }
            "setNotify" -> setNotify(call.arguments as? String ?: "", result)
            "read" -> read(call.arguments as? String ?: "", result)
            "write" -> write(
                call.argument<String>("uuid") ?: "",
                call.argument<ByteArray>("data") ?: ByteArray(0),
                call.argument<Boolean>("withoutResponse") == true,
                result,
            )
            "disconnect" -> {
                teardownGatt()
                result.success(null)
            }
            "bondDevice" -> ensurePermissions {
                bondDevice(
                    call.argument<String>("deviceId") ?: "",
                    call.argument<String>("name") ?: "",
                    call.argument<String>("serial") ?: "",
                    result,
                )
            }
            "openBluetoothSettings" -> result.success(openBluetoothSettings())
            "openWifiSettings" -> result.success(openWifiSettings())
            else -> result.notImplemented()
        }
    }

    /** API 31+ 须运行时授予 SCAN/CONNECT;29/30 走 FINE_LOCATION(已有)。 */
    private fun blePermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun ensurePermissions(onReady: () -> Unit) {
        val missing = blePermissions().filter {
            context?.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            onReady()
            return
        }
        val act = activity
        if (act == null || pendingPermission != null) {
            emit(
                mapOf(
                    "type" to "error", "code" to "permissionDenied",
                    "message" to "蓝牙权限未授权(无 Activity 或请求在途)", "uuid" to "",
                )
            )
            return
        }
        pendingPermission = onReady
        act.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
    }

    // ------------------------------------------------------------------
    // 扫描
    // ------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun startScan(seconds: Int, filterDeviceId: Int?, result: MethodChannel.Result) {
        if (scanResult != null) {
            result.error("busy", "已有扫描在进行", null)
            return
        }
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            result.error("scanFailed", "蓝牙未开启或不可用", null)
            return
        }
        scanFilterDeviceId = filterDeviceId
        scanHits = LinkedHashMap()
        scanResult = result
        val settings = android.bluetooth.le.ScanSettings.Builder()
            .setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(null, settings, scanCallback)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "startScan: $e")
            scanResult = null
            result.error("scanFailed", "$e", null)
            return
        }
        mainHandler.postDelayed({ finishScan() }, seconds * 1000L)
    }

    private val scanCallback = object : android.bluetooth.le.ScanCallback() {
        override fun onScanResult(callbackType: Int, result: android.bluetooth.le.ScanResult) {
            mainHandler.post { onScanResult(result) }
        }

        override fun onScanFailed(errorCode: Int) {
            mainHandler.post {
                android.util.Log.w(TAG, "onScanFailed: $errorCode")
                finishScan()
            }
        }
    }

    private fun onScanResult(sr: android.bluetooth.le.ScanResult) {
        if (scanResult == null) return
        val id = sr.device?.address ?: return
        if (id.isEmpty()) return
        val name = sr.scanRecord?.deviceName ?: ""
        val mfg = parseNikonMfg(sr.scanRecord)
        if (scanFilterDeviceId != null) {
            // 重连过滤:厂商数据 = 0x0399 + deviceId 小端 4B
            if (mfg.size < 6) return
            val dev = (mfg[2].toInt() and 0xFF) or
                ((mfg[3].toInt() and 0xFF) shl 8) or
                ((mfg[4].toInt() and 0xFF) shl 16) or
                ((mfg[5].toInt() and 0xFF) shl 24)
            if (dev != scanFilterDeviceId) return
        } else {
            // 配对扫描:尼康机身(名 Z 开头系 / LSS 服务 / 尼康厂商数据)
            val svcs = sr.scanRecord?.serviceUuids
            val svcHit = svcs?.any { it.toString().uppercase().contains("DE00") } == true
            val nameHit = name.startsWith("Z ") || name.contains("Z_f")
            if (!svcHit && mfg.isEmpty() && !nameHit) return
        }
        val hit = ScanHit(name, id, sr.rssi, mfg)
        scanHits[id] = hit
        emit(
            mapOf(
                "type" to "discovered", "name" to name, "uuid" to id,
                "rssi" to sr.rssi, "mfg" to mfg,
            )
        )
    }

    /** 取尼康厂商数据并补齐 [0x99,0x03] 前缀(Android map 值不含 ID 前缀)。 */
    private fun parseNikonMfg(record: android.bluetooth.le.ScanRecord?): ByteArray {
        if (record == null) return ByteArray(0)
        val v = try {
            record.getManufacturerSpecificData(NIKON_COMPANY_ID)
        } catch (e: Exception) {
            null
        } ?: return ByteArray(0)
        if (v.isEmpty()) return ByteArray(0)
        val out = ByteArray(v.size + 2)
        out[0] = 0x99.toByte()
        out[1] = 0x03
        v.copyInto(out, 2)
        return out
    }

    private fun stopScanNative() {
        mainHandler.removeCallbacks(finishRunnable)
        val scanner = try {
            adapter?.bluetoothLeScanner
        } catch (e: Exception) {
            null
        }
        if (scanner != null) {
            try {
                scanner.stopScan(scanCallback)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "stopScan: $e")
            }
        }
    }

    private val finishRunnable = Runnable { finishScan() }

    private fun finishScan() {
        stopScanNative()
        val result = scanResult
        scanResult = null
        if (result == null) return
        val list = scanHits.values.map {
            mapOf("name" to it.name, "uuid" to it.uuid, "rssi" to it.rssi, "mfg" to it.mfg)
        }
        result.success(list)
    }

    // ------------------------------------------------------------------
    // 连接 / GATT
    // ------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun connectPaired(uuid: String, result: MethodChannel.Result) {
        val adapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("connectFailed", "蓝牙未开启", null)
            return
        }
        if (gatt != null) {
            // 单客户端纪律:旧句柄不 close 会把迟到回调混进新连接
            teardownGatt()
        }
        deviceId = uuid
        charMap.clear()
        propsMap.clear()
        discoveryRetries = 0
        discoveryDone = false
        pendingConnect = result
        val device = try {
            adapter.getRemoteDevice(uuid)
        } catch (e: IllegalArgumentException) {
            pendingConnect = null
            result.error("connectFailed", "设备标识无效:$e", null)
            return
        }
        try {
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "connectGatt: $e")
            pendingConnect = null
            gatt = null
            result.error("connectFailed", "连接失败(蓝牙权限):$e", null)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "connectGatt: $e")
            NativeLog.w("ble", "connectGatt 失败:$e")
            pendingConnect = null
            gatt = null
            result.error("connectFailed", "$e", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun discoverServices() {
        val g = gatt ?: return // 迟到的看门狗回调
        if (discoveryDone || discoveryInFlight) return
        discoveryInFlight = true
        try {
            if (!g.discoverServices()) {
                discoveryInFlight = false
                settleConnect("discoveryFailed", "discoverServices 被拒")
            }
        } catch (e: Exception) {
            discoveryInFlight = false
            android.util.Log.e(TAG, "discoverServices: $e")
            settleConnect("discoveryFailed", "$e")
        }
    }

    private fun buildServiceTable() {
        charMap.clear()
        propsMap.clear()
        val g = gatt ?: return
        for (svc in g.services) {
            for (ch in svc.characteristics) {
                val u = ch.uuid.toString()
                charMap[u] = ch
                val flags = mutableListOf<String>()
                val props = ch.properties
                if (props and BluetoothGattCharacteristic.PROPERTY_READ != 0) flags.add("read")
                if (props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) flags.add("write")
                if (props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
                    flags.add("writeWithoutResponse")
                }
                if (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) flags.add("notify")
                if (props and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) flags.add("indicate")
                propsMap[u] = flags.joinToString("|")
            }
        }
    }

    private fun settleConnect(code: String?, message: String?) {
        val pending = pendingConnect
        pendingConnect = null
        if (code != null) {
            pending?.error(code, message, null)
        } else {
            pending?.success(null)
        }
    }

    /** 连接断开(意外/蓝牙关):在途连接与队列全落错,特征表清空。 */
    private fun onDisconnectedLocal() {
        mainHandler.removeCallbacksAndMessages(null)
        discoveryInFlight = false
        discoveryDone = false
        val hadConnection = gatt != null
        try {
            gatt?.close()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "close: $e")
        }
        gatt = null
        if (hadConnection) {
            emit(mapOf("type" to "disconnected", "uuid" to deviceId))
        }
        settleConnect("connectFailed", "连接在服务发现前断开")
        for (op in opQueue) {
            op.result?.error("disconnected", "连接已断开", null)
        }
        opQueue.clear()
        opBusy = false
        charMap.clear()
        propsMap.clear()
        settleBond(false, "连接已断开")
    }

    private fun findChar(uuid: String): BluetoothGattCharacteristic? = charMap[uuid]

    // ------------------------------------------------------------------
    // GATT op 队列(Android 单飞行纪律:读/写/描述符全串行)
    // ------------------------------------------------------------------

    private fun enqueue(op: PendingOp) {
        opQueue.addLast(op)
        if (!opBusy) flushOps()
    }

    @SuppressLint("MissingPermission")
    private fun flushOps() {
        val op = opQueue.removeFirstOrNull()
        if (op == null) {
            opBusy = false
            return
        }
        val g = gatt
        val ch = findChar(op.uuid)
        if (g == null || ch == null) {
            op.result?.error("notFound", "特征不存在:${op.uuid}", null)
            flushOps()
            return
        }
        opBusy = true
        val ok = try {
            when (op.kind) {
                OpKind.WRITE_CHAR -> {
                    ch.writeType = if (op.withoutResponse) {
                        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    } else {
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    }
                    g.writeCharacteristic(ch)
                }
                OpKind.WRITE_DESC -> {
                    val desc = ch.getDescriptor(UUID.fromString(CCCD_UUID))
                    if (desc == null) {
                        op.result?.error("notifyFailed", "CCCD 描述符缺失:${op.uuid}", null)
                        opBusy = false
                        flushOps()
                        return
                    }
                    desc.value = op.data
                    g.writeDescriptor(desc)
                }
                OpKind.READ -> g.readCharacteristic(ch)
            }
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "gatt op ${op.kind}: $e")
            op.result?.error(if (op.kind == OpKind.READ) "readFailed" else "writeFailed", "$e", null)
            opBusy = false
            flushOps()
            return
        } catch (e: Exception) {
            android.util.Log.e(TAG, "gatt op ${op.kind}: $e")
            op.result?.error(if (op.kind == OpKind.READ) "readFailed" else "writeFailed", "$e", null)
            opBusy = false
            flushOps()
            return
        }
        if (!ok) {
            op.result?.error(
                if (op.kind == OpKind.READ) "readFailed" else "writeFailed",
                "GATT 操作被拒(协议栈忙或特征不可写)",
                null,
            )
            opBusy = false
            flushOps()
        }
    }

    /** 回调收口:status == GATT_SUCCESS 时 result 带值/成功,然后取下一笔。 */
    private fun settleOp(status: Int, value: ByteArray?) {
        val op = opQueue.removeFirstOrNull()
        if (op == null) {
            opBusy = false
            return
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            op.result?.error(
                if (op.kind == OpKind.READ) "readFailed" else "writeFailed",
                "GATT status=$status",
                null,
            )
        } else if (op.kind == OpKind.READ) {
            op.result?.success(value)
        } else {
            op.result?.success(null)
        }
        flushOps()
    }

    private fun setNotify(uuid: String, result: MethodChannel.Result) {
        val ch = findChar(uuid)
        if (gatt == null || ch == null) {
            result.error("notFound", "特征不存在:$uuid", null)
            return
        }
        val indicate = (propsMap[uuid] ?: "").contains("indicate")
        // notify 0x0100 / indicate 0x0200(Android 两种都要显式写 CCCD)
        val cccd = if (indicate) byteArrayOf(0x02, 0x00) else byteArrayOf(0x01, 0x00)
        try {
            gatt?.setCharacteristicNotification(ch, true)
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "setCharacteristicNotification: $e")
            result.error("notifyFailed", "$e", null)
            return
        }
        enqueue(PendingOp(OpKind.WRITE_DESC, uuid, data = cccd, result = result))
    }

    private fun read(uuid: String, result: MethodChannel.Result) {
        if (gatt == null || findChar(uuid) == null) {
            result.error("notFound", "特征不存在:$uuid", null)
            return
        }
        enqueue(PendingOp(OpKind.READ, uuid, result = result))
    }

    private fun write(uuid: String, data: ByteArray, withoutResponse: Boolean, result: MethodChannel.Result) {
        if (gatt == null || findChar(uuid) == null) {
            result.error("notFound", "特征不存在:$uuid", null)
            return
        }
        enqueue(PendingOp(OpKind.WRITE_CHAR, uuid, data = data, withoutResponse = withoutResponse, result = result))
    }

    private fun teardownGatt() {
        mainHandler.removeCallbacksAndMessages(null)
        discoveryInFlight = false
        discoveryDone = false
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "teardown: $e")
        }
        gatt = null
        for (op in opQueue) {
            op.result?.error("disconnected", "连接已断开", null)
        }
        opQueue.clear()
        opBusy = false
        charMap.clear()
        propsMap.clear()
    }

    // ------------------------------------------------------------------
    // 程序化经典蓝牙绑定(Android 独有便利:BLE MAC 即经典 MAC,免发现)
    // ------------------------------------------------------------------

    private fun bondDevice(deviceId: String, name: String, serial: String, result: MethodChannel.Result) {
        if (deviceId.isEmpty()) {
            result.error("badArgs", "bondDevice 须传设备标识", null)
            return
        }
        val adapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("bondFailed", "蓝牙未开启", null)
            return
        }
        if (pendingBond != null) {
            result.error("busy", "已有绑定在途", null)
            return
        }
        val dev = try {
            adapter.getRemoteDevice(deviceId)
        } catch (e: IllegalArgumentException) {
            result.error("bondFailed", "设备标识无效:$e", null)
            return
        }
        this.deviceId = deviceId
        if (dev.bondState == BluetoothDevice.BOND_BONDED) {
            result.success(true)
            return
        }
        pendingBond = result
        val created = try {
            dev.createBond()
        } catch (e: SecurityException) {
            android.util.Log.e(TAG, "createBond: $e")
            pendingBond = null
            result.error("bondFailed", "配对请求失败(蓝牙权限):$e", null)
            return
        } catch (e: Exception) {
            android.util.Log.e(TAG, "createBond: $e")
            pendingBond = null
            result.error("bondFailed", "配对请求失败:$e", null)
            return
        }
        if (!created) {
            pendingBond = null
            result.error("bondFailed", "配对请求被系统拒绝", null)
            return
        }
        mainHandler.postDelayed({
            settleBond(false, "绑定响应超时")
        }, BOND_TIMEOUT_MS)
    }

    private fun settleBond(ok: Boolean, error: String?) {
        val pending = pendingBond ?: return
        pendingBond = null
        if (ok) {
            pending.success(true)
        } else {
            pending.error("bondRejected", error, null)
        }
    }

    // ------------------------------------------------------------------
    // 系统蓝牙设置页
    // ------------------------------------------------------------------

    private fun openBluetoothSettings(): Boolean {
        val ctx = activity ?: context ?: return false
        return try {
            ctx.startActivity(
                Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            android.util.Log.w(TAG, "openBluetoothSettings: $e")
            false
        }
    }

    /** 直达系统 Wi-Fi 设置页;蓝牙页 Wi-Fi 红卡手动按钮用(点了才跳)。 */
    private fun openWifiSettings(): Boolean {
        val ctx = activity ?: context ?: return false
        return try {
            ctx.startActivity(
                Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            android.util.Log.w(TAG, "openWifiSettings: $e")
            false
        }
    }

    // ------------------------------------------------------------------

    private fun currentState(): String = when (adapter?.state) {
        BluetoothAdapter.STATE_ON -> "poweredOn"
        BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
        BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
        BluetoothAdapter.STATE_OFF -> "poweredOff"
        else -> "unknown"
    }

    private fun safeName(dev: BluetoothDevice): String? = try {
        dev.name
    } catch (e: SecurityException) {
        null
    }

    private fun emit(payload: Map<String, Any?>) {
        sink?.success(payload)
    }
}
