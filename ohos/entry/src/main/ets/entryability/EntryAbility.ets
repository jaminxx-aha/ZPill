
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { UsbHostPlugin } from '../usbhost/UsbHostPlugin';
import { GalleryPlugin } from '../gallery/GalleryPlugin';
import { NsdPlugin } from '../nsd/NsdPlugin';
import { MotionPlugin } from '../motion/MotionPlugin';
import { LocationPlugin } from '../location/LocationPlugin';
import { BgPlugin } from '../bg/BgPlugin';
import { VideoPlugin } from '../video/VideoPlugin';
import { RawDecodePlugin } from '../raw/RawDecodePlugin';
import { BlePlugin } from '../ble/BlePlugin';
import { NetworkPlugin } from '../network/NetworkPlugin';
import { NativeLog } from '../log/NativeLog';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // 原生日志合流通道最先装(native → Dart 反向上报,契约
    // lib/platform/log_bridge.dart):后面任何插件早期的上报都有通道可用。
    NativeLog.install(flutterEngine.getDartExecutor().getBinaryMessenger())
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // app 内置通道(pub 依赖之外,GeneratedPluginRegistrant 不覆盖,须手动注册)
    flutterEngine.getPlugins()?.add(new UsbHostPlugin())
    flutterEngine.getPlugins()?.add(new GalleryPlugin())
    flutterEngine.getPlugins()?.add(new NsdPlugin())
    flutterEngine.getPlugins()?.add(new MotionPlugin())
    flutterEngine.getPlugins()?.add(new LocationPlugin())
    flutterEngine.getPlugins()?.add(new BgPlugin())
    flutterEngine.getPlugins()?.add(new VideoPlugin())
    flutterEngine.getPlugins()?.add(new RawDecodePlugin())
    flutterEngine.getPlugins()?.add(new BlePlugin())
    flutterEngine.getPlugins()?.add(new NetworkPlugin())
  }
}
