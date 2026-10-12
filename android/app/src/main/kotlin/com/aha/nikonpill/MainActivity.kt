package com.aha.nikonpill

import com.aha.nikonpill.bg.BgPlugin
import com.aha.nikonpill.gallery.GalleryPlugin
import com.aha.nikonpill.location.LocationPlugin
import com.aha.nikonpill.motion.MotionPlugin
import com.aha.nikonpill.nsd.NsdPlugin
import com.aha.nikonpill.usb.UsbHostPlugin
import com.aha.nikonpill.video.VideoPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // app 内置通道在 pub 依赖之外,GeneratedPluginRegistrant 不覆盖,
        // 与 ohos EntryAbility 的手动注册同构。
        flutterEngine.plugins.add(UsbHostPlugin())
        flutterEngine.plugins.add(GalleryPlugin())
        flutterEngine.plugins.add(NsdPlugin())
        flutterEngine.plugins.add(MotionPlugin())
        flutterEngine.plugins.add(LocationPlugin())
        flutterEngine.plugins.add(BgPlugin())
        flutterEngine.plugins.add(VideoPlugin())
    }
}
