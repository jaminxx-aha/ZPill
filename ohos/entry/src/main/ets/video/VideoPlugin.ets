/**
 * NikonPill 视频(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/video_player.dart(MethodChannel
 * `nikonpill/video`),当前覆盖抽帧、全屏播放与内嵌平台视图:
 *
 * - `thumbnail({path, maxPixelSize})`:@ohos.multimedia.media 的
 *   AVImageGenerator(API 12+,本 SDK @since 23 形态)取 0.1s 处一帧
 *   (iOS 取同点位避纯黑首帧;旋转语义待真机核对 —— 竖拍素材方向
 *   如实机表现),长边压到 maxPixelSize 内(PixelMap.scale 原地缩),
 *   ImagePacker.packToData 打包 JPEG 回传(必须 Uint8Array 包装 ——
 *   ArrayBuffer 过不了 MethodChannel 序列化,见 onMethodCall 内注,
 *   2026-10-24 实锤;Dart 侧收 Uint8List)。
 * - `frameRate({path})`:AVImageGenerator 无帧率元数据,AVMetadataHelper
 *   的帧数键在部分档不全 —— 先回 null(调用方不设顺帧门直放,契约
 *   合法),真机核对后如需再补。
 * - `play({path, rate})`:全屏播放(VideoSheet 覆盖层 + AVPlayer/
 *   XComponent,2026-10-13)。
 * - `viewLoad/viewControl/viewStatus/viewSeek`:内嵌播放平台视图
 *   (`nikonpill/video-view`,2026-10-24 对齐 iOS 页内播放)—— 实例
 *   在 video/VideoView.ets,本类只按 viewId 分发;工厂在
 *   onAttachedToEngine 注册。
 *
 * 通道调用在平台线程,解码重活全异步(await 链),result 回调在完成
 * 时交付(与 iOS 后台队列 + 主线程回投同语义)。
 */
import media from '@ohos.multimedia.media';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';
import { VideoSession } from './VideoSession';
import { VideoViewFactory, VideoViewRegistry } from './VideoView';

const TAG = 'VideoPlugin';
const CHANNEL = 'nikonpill/video';
const THUMB_TIME_US = 100000; // 0.1s,避纯黑首帧

/** `nikonpill/video` 通道实现(抽帧/全屏播放/内嵌视图分发)。 */
export class VideoPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'VideoPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    binding.getPlatformViewRegistry().registerViewFactory(
      'nikonpill/video-view', new VideoViewFactory());
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'thumbnail') {
      const path = call.argument('path') as string | null;
      const maxPixelSize = (call.argument('maxPixelSize') as number) ?? 512;
      if (path === null || path === undefined || path.length === 0) {
        result.error('bad_args', 'thumbnail 需要 path', null);
        return;
      }
      this.extractThumbnail(path, maxPixelSize).then((bytes) => {
        if (bytes !== null) {
          // 字节陷阱:MethodChannel 序列化(writeValue)不认 ArrayBuffer
          // —— 落 `typeof value == 'object'` 分支序列化成**空 map**,Dart
          // 侧 `as Uint8List` 翻 TypeError 被 on Object 吞掉 = 缩略静默
          // 消失(2026-10-24 ohos 真机实锤:AVImageGenerator 全程无错、
          // 缓存零落盘)。必须 new Uint8Array 包一层(iOS 裸 Data →
          // FlutterStandardTypedData 同款教训)。
          result.success(new Uint8Array(bytes));
        } else {
          result.error('thumbnail_failed', `抽帧失败:${path}`, null);
        }
      }).catch((err: Object) => {
        result.error('thumbnail_failed', `抽帧失败:${JSON.stringify(err)}`, null);
      });
      return;
    }
    if (call.method === 'play') {
      const path = call.argument('path') as string | null;
      const rate = (call.argument('rate') as number) ?? 1.0;
      const position = (call.argument('position') as number) ?? 0;
      if (path === null || path === undefined || path.length === 0) {
        result.error('bad_args', 'play 需要 path', null);
        return;
      }
      const started = VideoSession.play(
        { path: path, rate: rate, position: position },
        (positionSec: number | null) => {
          try {
            result.success(positionSec); // 关闭时刻位置(续播);null = 未知
          } catch (_) {
            // 回调已交付过(双关闭护栏在 VideoSession)
          }
        });
      if (!started) {
        result.error('busy', '已有全屏播放在进行', null);
      }
      return;
    }
    if (call.method === 'frameRate') {
      // 帧率探测暂无可靠元数据源:回 null = 调用方不设顺帧门直放。
      result.success(null);
      return;
    }
    if (call.method === 'viewLoad') {
      // 视图未创建/已销毁静默忽略(iOS loadEmbeddedView 同语义)
      const id = (call.argument('id') as number) ?? -1;
      const path = call.argument('path') as string | null;
      const view = VideoViewRegistry.get(id);
      if (view === null || path === null || path === undefined ||
        path.length === 0) {
        result.success(null);
        return;
      }
      view.load(path);
      result.success(null);
      return;
    }
    if (call.method === 'viewControl') {
      const id = (call.argument('id') as number) ?? -1;
      const playing = (call.argument('playing') as boolean) ?? false;
      const rate = (call.argument('rate') as number) ?? 1.0;
      VideoViewRegistry.get(id)?.control(playing, rate);
      result.success(null);
      return;
    }
    if (call.method === 'viewStatus') {
      const id = (call.argument('id') as number) ?? -1;
      const view = VideoViewRegistry.get(id);
      if (view === null) {
        const idle: Record<string, Object> = {
          'position': 0, 'duration': 0, 'playing': false,
        };
        result.success(idle);
        return;
      }
      result.success(view.status());
      return;
    }
    if (call.method === 'viewSeek') {
      const id = (call.argument('id') as number) ?? -1;
      const position = (call.argument('position') as number) ?? 0;
      VideoViewRegistry.get(id)?.seek(position);
      result.success(null);
      return;
    }
    result.notImplemented();
  }

  /** 抽帧:0.1s 处 PixelMap → 长边原地压档 → JPEG ArrayBuffer。 */
  private async extractThumbnail(path: string, maxPixelSize: number):
    Promise<ArrayBuffer | null> {
    let generator: media.AVImageGenerator | null = null;
    let packer: image.ImagePacker | null = null;
    let pixelMap: image.PixelMap | null = null;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      generator = await media.createAVImageGenerator();
      generator.fdSrc = { fd: file.fd };
      const params: media.PixelMapParams = {};
      pixelMap = await generator.fetchFrameByTime(
        THUMB_TIME_US,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        params,
      );
      // 长边压档(scale 是原地变换;已小于目标则原样)
      const info = await pixelMap.getImageInfo();
      const longSide = Math.max(info.size.width, info.size.height);
      if (longSide > maxPixelSize && longSide > 0) {
        const ratio = maxPixelSize / longSide;
        try {
          await pixelMap.scale(ratio, ratio);
        } catch (err) {
          Log.w(TAG, `scale 失败,用原尺寸:${JSON.stringify(err)}`);
        }
      }
      packer = image.createImagePacker();
      const buf = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 85,
      });
      return buf;
    } catch (err) {
      Log.w(TAG, `thumbnail 异常:${JSON.stringify(err)}`);
      return null;
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (generator !== null) {
        try {
          await generator.release();
        } catch (_) {
          // 释放尽力而为
        }
      }
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_) {
          // 释放尽力而为
        }
      }
    }
  }
}
