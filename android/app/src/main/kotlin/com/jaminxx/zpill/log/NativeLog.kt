package com.jaminxx.zpill.log

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * ZPill 原生日志上报(Android 平台,native 侧)—— native → Dart 反向通道。
 *
 * 对应 Dart 契约 lib/platform/log_bridge.dart(MethodChannel `zpill/log`):
 * native → Dart 调 'onNativeLog',参数 {level: "d"|"i"|"w"|"e", tag, line},
 * 由 Dart 合流进 AppLog 的 native 域。三端 native 在关键路径(USB bulk
 * 失败 / BLE 状态沿)显式上报、不做 logcat 抓流;iOS/ohos 各有对等件
 * (NativeLog.swift / NativeLog.ets,同名同参)。
 *
 * 契约要点(与 Dart 侧注释一致):
 * - fire-and-forget:invoke 全部 try/catch 吞错(Dart handler 未装配 /
 *   引擎已 detach 都不反噬调用方);不带 result 回调,回复天然丢弃。
 * - 恒主线程 invoke:调用方多在 ioExecutor(USB bulk)等后台线程,
 *   统一 Handler(mainLooper) 收口(先例:VideoLutExportPlugin 的
 *   onProgress 反向推送、UsbHostPlugin 的 postSuccess/postError)。
 * - install 前的上报静默丢弃(channel 为 null 直接返回);MainActivity
 *   在 configureFlutterEngine 最先装配,早于一切插桩点。
 */
object NativeLog {
    private const val CHANNEL = "zpill/log"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 反向通道;@Volatile:install 在主线程、send 的判空在 executor 线程。 */
    @Volatile
    private var channel: MethodChannel? = null

    /**
     * 装配点(MainActivity 在 configureFlutterEngine 里调)。无条件覆写:
     * 引擎重建即换 messenger,旧通道指向死引擎只会白抛异常(先例:
     * MainActivity 的 volumeChannel 同款重装,不做幂等守卫)。
     */
    fun install(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
    }

    fun e(tag: String, line: String) = send("e", tag, line)
    fun w(tag: String, line: String) = send("w", tag, line)
    fun i(tag: String, line: String) = send("i", tag, line)

    private fun send(level: String, tag: String, line: String) {
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod(
                    "onNativeLog",
                    mapOf("level" to level, "tag" to tag, "line" to line),
                )
            } catch (_: Exception) {
                // Dart handler 未装配 / 引擎已 detach:fire-and-forget,吞掉
            }
        }
    }
}
