/**
 * 全屏视频播放会话(ohos;`zpill/video` play 的宿主)。
 *
 * 对应 iOS VideoPlugin.swift 的 AVKit 全屏路径与 Android VideoActivity:
 * VideoPlugin.play 只登记请求并亮覆盖层(Index.ets 内 VideoSheet,
 * SaveSheet 同款 Stack 覆盖),关闭钮/播完 → VideoSession.close() →
 * 一次性交回 MethodResult(success(null))。
 *
 * 模块级单例:插件与 UI 同进程同模块实例直连,不经共享存储
 * (SaveSession 同款——FlutterAbility 私有 LocalStorage,共享不可达)。
 *
 * 速率语义:AVPlayer.setPlaybackRate 只收预设档(0.75/1.0/1.25/1.75/
 * 2.0),无任意速率 —— 顺帧预览(24/fps,如 0.4)取**不超请求的最近
 * 预设**(0.4→0.75 会比请求快,取「最接近」更诚实,标定待真机核对);
 * rate ≠ 1 一律静音(setVolume 0,变速下音轨无意义,OpenZCine/iOS/
 * Android 同款)。播放器本体在 VideoSheet(AVPlayer + XComponent),
 * 本类只管请求登记/可见性/结果交付。
 */
import { Log } from '@ohos/flutter_ohos';

const TAG = 'VideoSession';

/** 播放请求。 */
export interface VideoRequest {
  path: string;
  rate: number;
}

/** 播放结束回调:用户关闭或播完时调用一次(错误经 result.error 交付)。 */
export type VideoFinish = () => void;

/** 面板可见性监听(Index.ets 注册;注册时回放当前态)。 */
export type VideoVisibilityListener = (visible: boolean) => void;

export class VideoSession {
  private static request: VideoRequest | null = null;
  private static finishCallback: VideoFinish | null = null;
  private static visibilityListener: VideoVisibilityListener | null = null;
  private static closed = false;

  static isActive(): boolean {
    return VideoSession.finishCallback !== null;
  }

  static current(): VideoRequest | null {
    return VideoSession.request;
  }

  static setVisibilityListener(listener: VideoVisibilityListener | null): void {
    VideoSession.visibilityListener = listener;
    if (listener !== null) {
      listener(VideoSession.isActive());
    }
  }

  /** 登记播放请求并亮覆盖层。已有会话在途 = 拒新请求(上层 busy)。 */
  static play(request: VideoRequest, finish: VideoFinish): boolean {
    if (VideoSession.finishCallback !== null) {
      return false;
    }
    VideoSession.request = request;
    VideoSession.finishCallback = finish;
    VideoSession.closed = false;
    VideoSession.visibilityListener?.(true);
    return true;
  }

  /** 播放页关闭(关闭钮/播完/返回键):交回结果并熄层。 */
  static close(): void {
    if (VideoSession.closed) {
      return;
    }
    VideoSession.closed = true;
    const finish = VideoSession.finishCallback;
    VideoSession.finishCallback = null;
    VideoSession.request = null;
    VideoSession.visibilityListener?.(false);
    Log.i(TAG, 'close:交付结果');
    finish?.();
  }
}
