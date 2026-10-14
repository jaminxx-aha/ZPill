package com.aha.nikonpill

import android.view.KeyEvent
import com.aha.nikonpill.bg.BgPlugin
import com.aha.nikonpill.ble.BlePlugin
import com.aha.nikonpill.gallery.GalleryPlugin
import com.aha.nikonpill.location.LocationPlugin
import com.aha.nikonpill.motion.MotionPlugin
import com.aha.nikonpill.network.NetworkPlugin
import com.aha.nikonpill.nsd.NsdPlugin
import com.aha.nikonpill.usb.UsbHostPlugin
import com.aha.nikonpill.video.VideoPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val VOLUME_CHANNEL = "nikonpill/volume"
    }

    /// 音量键快门反向通道(Dart 契约 lib/platform/volume_keys.dart):
    /// Dart 经 'setEnabled'(bool) 推开关(默认 false = 不拦,音量键
    /// 归系统);开关开时 onKeyUp 命中音量键即回推 'onVolumeKey'。
    /// engine 就绪前(channel 未建)按键一律放行系统,判空不炸。
    private var volumeChannel: MethodChannel? = null
    private var volumeShutterEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // app 内置通道在 pub 依赖之外,GeneratedPluginRegistrant 不覆盖,
        // 与 ohos EntryAbility 的手动注册同构。
        flutterEngine.plugins.add(UsbHostPlugin())
        flutterEngine.plugins.add(GalleryPlugin())
        flutterEngine.plugins.add(NsdPlugin())
        flutterEngine.plugins.add(MotionPlugin())
        flutterEngine.plugins.add(LocationPlugin())
        flutterEngine.plugins.add(BlePlugin())
        flutterEngine.plugins.add(BgPlugin())
        flutterEngine.plugins.add(VideoPlugin())
        flutterEngine.plugins.add(NetworkPlugin())
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VOLUME_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        volumeShutterEnabled = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        volumeChannel?.setMethodCallHandler(null)
        volumeChannel = null
        volumeShutterEnabled = false
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        val channel = volumeChannel
        // 只拦 ACTION_UP:长按的连发都在 DOWN,不拦 DOWN = 音量长按
        // 调节仍归系统;开关开着 + 通道已建才拦,命中即回推 Dart,
        // 返回 true 吃掉系统音量变化。
        if (volumeShutterEnabled &&
            channel != null &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
                keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            channel.invokeMethod(
                "onVolumeKey",
                mapOf(
                    "key" to
                        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down"
                )
            )
            return true
        }
        return super.onKeyUp(keyCode, event)
    }
}
