/**
 * NikonPill 视频(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/video_player.dart(MethodChannel
 * `nikonpill/video`),本轮落**抽帧**方法(iOS VideoPlugin.swift 已在
 * 产;全屏 play/内嵌播放 ohos 待补 —— 调用方回落路径不依赖它们):
 *
 * - `thumbnail({path, maxPixelSize})`:@ohos.multimedia.media 的
 *   AVImageGenerator(API 12+,本 SDK @since 23 形态)取 0.1s 处一帧
 *   (iOS 取同点位避纯黑首帧;旋转语义待真机核对 —— 竖拍素材方向
 *   如实机表现),长边压到 maxPixelSize 内(PixelMap.scale 原地缩),
 *   ImagePacker.packToData 打包 JPEG 回传 ArrayBuffer(Dart 侧收
 *   Uint8List)。
 * - `frameRate({path})`:AVImageGenerator 无帧率元数据,AVMetadataHelper
 *   的帧数键在部分档不全 —— 先回 null(调用方不设顺帧门直放,契约
 *   合法),真机核对后如需再补。
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

const TAG = 'VideoPlugin';
const CHANNEL = 'nikonpill/video';
const THUMB_TIME_US = 100000; // 0.1s,避纯黑首帧

/** `nikonpill/video` 通道实现(抽帧;播放/内嵌 ohos 待补)。 */
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
          result.success(bytes);
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
      if (path === null || path === undefined || path.length === 0) {
        result.error('bad_args', 'play 需要 path', null);
        return;
      }
      const started = VideoSession.play({ path: path, rate: rate }, () => {
        try {
          result.success(null);
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
