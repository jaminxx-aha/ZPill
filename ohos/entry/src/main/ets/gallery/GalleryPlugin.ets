/**
 * NikonPill 相册/文件通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/gallery_saver.dart:
 * - tempDir()/thumbsDir()/previewsDir():cacheDir 下专用子目录(缓存,
 *   系统可回收;缩略图 LRU 与下载临时落盘用);
 * - downloadsDir():filesDir 下持久目录(「下载到应用」的目的地);
 * - importFiles([{path, kind('image'|'video'), filename, videoPath?}]):
 *   批量导入系统相册 —— SaveButton 安全控件路径(见 SaveSession/
 *   SaveSheet):importFiles 只登记请求并亮面板,用户点保存按钮获得
 *   临时授权后由 native 侧 createAsset + 拷字节,结果经回调异步回传。
 *   用户取消 → 空列表 → Dart 侧任务标「未导入」。
 *   videoPath 非空 = 实况照片配对段(静帧 + 运动视频):ohos 无实况
 *   照片合成 API → 分开导入两个资产,详见 SaveSession.performSave。
 *
 * 面板挂在 Index.ets 的覆盖层上,需要 UIAbility 存活,插件实现
 * AbilityAware 拿 UIAbility 引用(EntryAbility 经
 * FlutterEngineConnectionRegistry 自动回调,无需额外接线)。
 */
import fs from '@ohos.file.fs';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  AbilityAware,
  AbilityPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';
import { SaveRequest, SaveSession } from './SaveSession';

const TAG = 'GalleryPlugin';

const TEMP_SUBDIR = 'nikonpill';
const THUMBS_SUBDIR = 'nikonpill-thumbs';
const PREVIEWS_SUBDIR = 'nikonpill-previews';
const DOWNLOADS_SUBDIR = 'nikonpill-downloads';
const DATA_SUBDIR = 'nikonpill-data';

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
      case 'dataDir':
        // 持久应用数据(客户端身份/配对记录):filesDir 下专用子目录
        this.filesSubDir(DATA_SUBDIR, result);
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
   * 批量导入系统相册(SaveButton 安全控件路径)。
   * 入参(Dart invokeListMethod):[{path, kind('image'|'video'), filename}]。
   * 出参:授权 URI 列表(与入参等长);用户取消 → 空列表;结果面板
   * 结束后异步回传(面板可能停留任意久,MethodResult 允许延迟应答)。
   */
  private importFiles(call: MethodCall, result: MethodResult): void {
    if (this.ability === null) {
      Log.e(TAG, 'importFiles: UIAbility 未挂载(AbilityAware 未回调)');
      result.error('gallery_error', 'UIAbility 未挂载(AbilityAware 未回调)', null);
      return;
    }
    const ability = this.ability; // 收窄:UIAbility(createAsset 要它的 context)
    try {
      // 标准编解码把 Dart Map 落成 ES Map(string 键)。
      // arkts 禁 any/unknown:args(ESObject)先 as 成具体形参类型,
      // 取值一律经 strValue() 收敛为 string(缺键/空值 → '')。
      const items = call.args as Array<Map<string, Object>>;
      if (items === null || items.length === 0) {
        result.error('gallery_error', 'importFiles 参数须为非空列表', null);
        return;
      }
      const requests: Array<SaveRequest> = [];
      for (const item of items) {
        const path = this.strValue(item.get('path'));
        const kind = this.strValue(item.get('kind'));
        const filename = this.strValue(item.get('filename'));
        if (path.length === 0 || filename.length === 0) {
          result.error('gallery_error', 'importFiles 项缺 path/filename', null);
          return;
        }
        const req: SaveRequest = { path: path, kind: kind, filename: filename };
        const videoPath = this.strValue(item.get('videoPath'));
        if (videoPath.length > 0) {
          req.videoPath = videoPath;
          // 显示名取路径末段(临时目录名无意义,title/扩展名才有)
          const slash = videoPath.lastIndexOf('/');
          req.videoFilename =
            slash >= 0 ? videoPath.substring(slash + 1) : videoPath;
        }
        requests.push(req);
      }
      if (SaveSession.isActive()) {
        result.error('gallery_error', '已有保存面板在进行中', null);
        return;
      }
      if (this.hasWritePermission(ability)) {
        // ACL 直授:WRITE_IMAGEVIDEO 常权在手,免面板静默落库
        Log.i(TAG, `importFiles: 已持 WRITE_IMAGEVIDEO,静默直存 ${requests.length} 个`);
        SaveSession.openSilent(ability.context,
          requests, (uris: Array<string>) => {
          Log.i(TAG, `静默保存完成:${uris.length}/${requests.length} 个 URI`);
          result.success(uris);
        }, (msg: string) => {
          result.error('gallery_error', `保存失败:${msg}`, null);
        });
        return;
      }
      Log.i(TAG, `importFiles: 登记 ${requests.length} 个文件,亮出保存面板`);
      const opened = SaveSession.open(requests, (uris: Array<string>) => {
        Log.i(TAG, `保存面板结束:${uris.length}/${requests.length} 个授权 URI`);
        result.success(uris);
      });
      if (!opened) {
        result.error('gallery_error', '保存面板 UI 未挂载(Index 未注册)', null);
      }
    } catch (e) {
      Log.e(TAG, `importFiles 异常: ${e}`);
      result.error('gallery_error', `importFiles: ${e}`, null);
    }
  }

  /// WRITE_IMAGEVIDEO 是否已持权(ACL 直授/临时授权均算):持权 =
  /// 免面板直存,否则走 SaveButton 面板。
  private hasWritePermission(ability: UIAbility): boolean {
    try {
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const state: abilityAccessCtrl.GrantStatus = at.verifyAccessTokenSync(
        ability.context.applicationInfo.accessTokenId,
        'ohos.permission.WRITE_IMAGEVIDEO');
      return state === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      Log.e(TAG, `hasWritePermission: ${e}`);
      return false;
    }
  }

  /// Map 取值收敛为 string(缺键/undefined/null → '')。
  private strValue(v: Object | undefined): string {
    return v === undefined || v === null ? '' : `${v}`;
  }
}
