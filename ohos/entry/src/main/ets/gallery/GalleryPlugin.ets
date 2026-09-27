/**
 * NikonBridge 相册/文件通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/gallery_saver.dart:
 * - tempDir():应用缓存目录下的专用子目录(Dart 侧用 dart:io 把
 *   getObject 流写成临时文件,零新依赖,不引 path_provider);
 * - importFile 后置(Phase E):HarmonyOS NEXT 三方应用静默写入媒体库
 *   受安全控件(SaveButton)限制,Flutter 视图内无法弹 ArkUI 安全控件;
 *   v1 后备 = 文件落 App 沙箱 + 展示路径(plan 已在案)。
 */
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
} from '@ohos/flutter_ohos';

const TAG = 'GalleryPlugin';

const TEMP_SUBDIR = 'nikonbridge';

/** `nikonbridge/gallery` 通道实现。 */
export class GalleryPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;

  getUniqueClassName(): string {
    return 'GalleryPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nikonbridge/gallery');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'tempDir':
        this.tempDir(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// 缓存目录下专用子目录,不存在则创建;返回绝对路径。
  private tempDir(result: MethodResult): void {
    if (this.context === null) {
      result.error('gallery_error', 'context 未就绪', null);
      return;
    }
    const dir = `${this.context.cacheDir}/${TEMP_SUBDIR}`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      result.success(dir);
    } catch (e) {
      result.error('gallery_error', `tempDir: ${e}`, null);
    }
  }
}
