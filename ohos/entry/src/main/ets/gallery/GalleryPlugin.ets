/**
 * NikonPill 相册/文件通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/gallery_saver.dart:
 * - tempDir()/thumbsDir()/previewsDir():cacheDir 下专用子目录(缓存,
 *   系统可回收;缩略图 LRU 与下载临时落盘用);
 * - downloadsDir():filesDir 下持久目录(「下载到应用」的目的地);
 * - importFiles(paths, kinds, filenames):批量导入系统相册 ——
 *   HarmonyOS NEXT 三方应用静默写媒体库需 ACL 特批,免权限路径是
 *   photoAccessHelper.showAssetsCreationDialog(系统保存对话框,
 *   since 12):每批一次,用户确认后应用把源文件字节拷进授权 URI。
 *   用户取消 → 对话框返回空列表 → Dart 侧任务标「未导入」。
 *
 * 弹系统对话框需要 UIAbility context(非 application context),
 * 插件实现 AbilityAware 拿 UIAbility 引用(EntryAbility 经
 * FlutterEngineConnectionRegistry 自动回调,无需额外接线)。
 */
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  AbilityAware,
  AbilityPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
} from '@ohos/flutter_ohos';

const TAG = 'GalleryPlugin';

const TEMP_SUBDIR = 'nikonpill';
const THUMBS_SUBDIR = 'nikonpill-thumbs';
const PREVIEWS_SUBDIR = 'nikonpill-previews';
const DOWNLOADS_SUBDIR = 'nikonpill-downloads';

/** `nikonpill/gallery` 通道实现。 */
export class GalleryPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private ability: UIAbility | null = null;

  getUniqueClassName(): string {
    return 'GalleryPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/gallery');
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

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
  }

  onDetachedFromAbility(): void {
    this.ability = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'tempDir':
        this.cacheSubDir(TEMP_SUBDIR, result);
        break;
      case 'thumbsDir':
        this.cacheSubDir(THUMBS_SUBDIR, result);
        break;
      case 'previewsDir':
        this.cacheSubDir(PREVIEWS_SUBDIR, result);
        break;
      case 'downloadsDir':
        this.filesSubDir(DOWNLOADS_SUBDIR, result);
        break;
      case 'importFiles':
        this.importFiles(call, result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// 缓存目录(cacheDir)下专用子目录,不存在则创建;返回绝对路径。
  private cacheSubDir(sub: string, result: MethodResult): void {
    if (this.context === null) {
      result.error('gallery_error', 'context 未就绪', null);
      return;
    }
    this.ensureDir(`${this.context.cacheDir}/${sub}`, sub, result);
  }

  /// 持久目录(filesDir)下专用子目录(「下载到应用」的目的地)。
  private filesSubDir(sub: string, result: MethodResult): void {
    if (this.context === null) {
      result.error('gallery_error', 'context 未就绪', null);
      return;
    }
    this.ensureDir(`${this.context.filesDir}/${sub}`, sub, result);
  }

  private ensureDir(dir: string, name: string, result: MethodResult): void {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      result.success(dir);
    } catch (e) {
      result.error('gallery_error', `${name}: ${e}`, null);
    }
  }

  /**
   * 批量导入系统相册。
   * 入参(Dart invokeListMethod):[{path, kind('image'|'video'), filename}]。
   * 出参:授权 URI 列表(与入参等长);用户取消 → 空列表。
   */
  private async importFiles(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.ability === null) {
      result.error('gallery_error', 'UIAbility 未挂载(AbilityAware 未回调)', null);
      return;
    }
    try {
      // 标准编解码把 Dart Map 落成 ES Map(string 键)。
      // arkts 禁 any/unknown:args(ESObject)先 as 成具体形参类型,
      // 取值一律经 strValue() 收敛为 string(缺键/空值 → '')。
      const items = call.args as Array<Map<string, Object>>;
      if (items === null || items.length === 0) {
        result.error('gallery_error', 'importFiles 参数须为非空列表', null);
        return;
      }
      const paths: Array<string> = [];
      const kinds: Array<string> = [];
      const names: Array<string> = [];
      for (const item of items) {
        const path = this.strValue(item.get('path'));
        const kind = this.strValue(item.get('kind'));
        const filename = this.strValue(item.get('filename'));
        if (path.length === 0 || filename.length === 0) {
          result.error('gallery_error', 'importFiles 项缺 path/filename', null);
          return;
        }
        paths.push(path);
        kinds.push(kind);
        names.push(filename);
      }
      const helper = photoAccessHelper.getPhotoAccessHelper(this.ability.context);
      const srcUris: Array<string> = paths.map(p => `file://${p}`);
      const configs: Array<photoAccessHelper.PhotoCreationConfig> = [];
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        const dot = name.lastIndexOf('.');
        const title = dot > 0 ? name.substring(0, dot) : name;
        const ext = dot > 0 ? name.substring(dot + 1) : '';
        const config: photoAccessHelper.PhotoCreationConfig = {
          title: title,
          fileNameExtension: ext,
          photoType: kinds[i] === 'video'
            ? photoAccessHelper.PhotoType.VIDEO
            : photoAccessHelper.PhotoType.IMAGE,
        };
        configs.push(config);
      }
      // 系统保存对话框:用户确认一批(或取消)。取消 → 空列表/抛错,
      // 两种形态都由 Dart 侧落成「未导入」。
      const uris = await helper.showAssetsCreationDialog(srcUris, configs);
      if (uris.length !== paths.length) {
        result.success([]);
        return;
      }
      // 授权 URI 只是占位:把源文件字节逐个拷入。
      for (let i = 0; i < paths.length; i++) {
        const src = fs.openSync(paths[i], fs.OpenMode.READ_ONLY);
        try {
          const dst = fs.openSync(uris[i], fs.OpenMode.READ_WRITE);
          try {
            fs.copyFileSync(src.fd, dst.fd);
          } finally {
            fs.closeSync(dst);
          }
        } finally {
          fs.closeSync(src);
        }
      }
      result.success(uris);
    } catch (e) {
      result.error('gallery_error', `importFiles: ${e}`, null);
    }
  }

  /// Map 取值收敛为 string(缺键/undefined/null → '')。
  private strValue(v: Object | undefined): string {
    return v === undefined || v === null ? '' : `${v}`;
  }
}
