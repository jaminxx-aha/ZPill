
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { UsbHostPlugin } from '../usbhost/UsbHostPlugin';
import { GalleryPlugin } from '../gallery/GalleryPlugin';
import { NsdPlugin } from '../nsd/NsdPlugin';
import { MotionPlugin } from '../motion/MotionPlugin';
import { LocationPlugin } from '../location/LocationPlugin';
import { BgPlugin } from '../bg/BgPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // app 内置通道(pub 依赖之外,GeneratedPluginRegistrant 不覆盖,须手动注册)
    flutterEngine.getPlugins()?.add(new UsbHostPlugin())
    flutterEngine.getPlugins()?.add(new GalleryPlugin())
    flutterEngine.getPlugins()?.add(new NsdPlugin())
    flutterEngine.getPlugins()?.add(new MotionPlugin())
    flutterEngine.getPlugins()?.add(new LocationPlugin())
    flutterEngine.getPlugins()?.add(new BgPlugin())
  }
}
