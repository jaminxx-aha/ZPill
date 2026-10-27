/**
 * 内嵌视频播放平台视图(ohos 侧;`zpill/video-view`)。
 *
 * 对应 Dart 契约 lib/platform/video_player.dart 的内嵌播放一路(iOS
 * UiKitView 同款语义,2026-10-24 对齐 iOS 页内播放):OhosView 工厂创建
 * XComponent 面,AVPlayer 挂 surfaceId 出画;档案路径不走平台视图
 * creationParams(引擎编解码钩子不可靠,iOS 同款教训),Dart 在
 * onCreated 回传 viewId 后经 `zpill/video` 通道 viewLoad 显式装载。
 *
 * 通道方法(VideoPlugin 按本文件注册表分发):
 * - `viewLoad({id, path})`:装载档案(idle → fdSrc)。
 * - `viewControl({id, playing, rate})`:起播/暂停 + 速率(顺帧 = 24/fps;
 *   非 1 速率静音,iOS/Android/全屏 VideoSheet 同契约)。
 * - `viewStatus({id})`:位置/时长(秒)与是否在播(Dart 250ms 轮询)。
 * - `viewSeek({id, position})`:拖进度条定位(秒)。
 *
 * 状态机与 VideoSheet 同款教训:**先挂满回调再设 fdSrc**(idle→
 * initialized 异步落地,surfaceId 只能在 'initialized' 回调设 ——
 * 5400102 实锤);'prepared' 才可变速/静音(setSpeed 档位限制)。
 * 装载门槛 = 路径与 surface 双就位(viewLoad 与 XComponent onLoad
 * 时序不定,两路都触发 maybeStart)。
 *
 * 面本体 = XComponent('surface'),id 挂 viewId 防多实例撞名;画面
 * 宽高比按 videoSizeChange 收进(Stack + aspectRatio letterbox,与
 * VideoSheet 同法)。播放控制全在 Flutter 侧浮层(EmbeddedVideoPlayer
 * 点按层盖在平台视图上,iOS 同款),native 面无触摸诉求。
 */
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import {
  Log,
  PlatformView,
  PlatformViewFactory,
  StandardMessageCodec,
} from '@ohos/flutter_ohos';

const TAG = 'VideoView';

/**
 * 引擎 builder 参数形状(har 未导出 Params 类型,按调用点
 * EmbeddingNodeController 的字面量形状本地声明:结构一致即过编译,
 * 运行时由引擎以同形状字面量传入)。
 */
declare class Params {
  direction: Direction;
  platformView: PlatformView;
}

/** 内嵌视图实例注册表:viewId 寻址(VideoPlugin 的 view* 方法分发)。 */
export class VideoViewRegistry {
  private static instances = new Map<number, VideoViewPlatformView>();

  static put(instance: VideoViewPlatformView): void {
    VideoViewRegistry.instances.set(instance.viewId, instance);
  }

  static get(viewId: number): VideoViewPlatformView | null {
    return VideoViewRegistry.instances.get(viewId) ?? null;
  }

  static remove(viewId: number): void {
    VideoViewRegistry.instances.delete(viewId);
  }
}

/** 平台视图工厂:每个 OhosView 实例一个 VideoViewPlatformView。 */
export class VideoViewFactory extends PlatformViewFactory {
  constructor() {
    super(new StandardMessageCodec());
  }

  create(context: common.Context, viewId: number, args: ESObject): PlatformView {
    const view = new VideoViewPlatformView(viewId);
    VideoViewRegistry.put(view);
    return view;
  }
}

/** 速率档就近(与 VideoSheet 同表):顺帧 0.4 → 0.5。 */
function resolveSpeed(rate: number): media.PlaybackSpeed {
  if (rate < 0.6) {
    return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
  } else if (rate < 1) {
    return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
  } else if (rate > 1 && rate <= 1.5) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
  } else if (rate > 1.5 && rate <= 1.9) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
  } else if (rate > 1.9) {
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }
  return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
}

/**
 * 平台视图本体:持有 AVPlayer,面由 [VideoViewFace] 渲染;错误只落
 * 日志不打断(Flutter 浮层照常工作,轮询见 playing=false)。
 */
export class VideoViewPlatformView extends PlatformView {
  readonly viewId: number;
  private path: string = '';
  private surfaceId: string = '';
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;
  private surfaceBound = false;
  private released = false;
  // 起播意图与速率:控制指令可能先于 prepared 到(prepare 异步),
  // 意图先落账,prepared 回调按账兜。
  private playingIntent = false;
  private rateIntent = 1.0;
  // 面组件回引用(videoSizeChange 驱动宽高比);aboutToAppear 挂上。
  private faceComponent: VideoViewFace | null = null;

  constructor(viewId: number) {
    super();
    this.viewId = viewId;
  }

  /** [VideoViewFace] aboutToAppear 挂回(宽高比驱动用)。 */
  attachFace(face: VideoViewFace): void {
    this.faceComponent = face;
  }

  getView(): WrappedBuilder<[Params]> {
    return wrapBuilder(buildVideoView);
  }

  dispose(): void {
    this.released = true;
    this.faceComponent = null;
    VideoViewRegistry.remove(this.viewId);
    const avPlayer = this.player;
    this.player = null;
    if (avPlayer !== null) {
      try {
        avPlayer.off('stateChange');
        avPlayer.off('error');
        avPlayer.off('videoSizeChange');
        if (this.surfaceBound) {
          avPlayer.surfaceId = '';
        }
      } catch (_) {
        // 摘面尽力而为
      }
      avPlayer.release().catch((_e: Object) => {
        // 释放尽力而为
      });
    }
    if (this.file !== null) {
      try {
        fs.closeSync(this.file);
      } catch (_) {
        // 释放尽力而为
      }
      this.file = null;
    }
  }

  /** XComponent 面就位([VideoViewFace] onLoad 回投)。 */
  onSurfaceReady(controller: XComponentController): void {
    const id = controller.getXComponentSurfaceId();
    if (id === '') {
      return;
    }
    this.surfaceId = id;
    this.maybeStart();
  }

  /** 通道 viewLoad:装载档案。 */
  load(path: string): void {
    this.path = path;
    this.maybeStart();
  }

  /** 通道 viewControl:起播/暂停 + 速率。 */
  control(playing: boolean, rate: number): void {
    this.playingIntent = playing;
    this.rateIntent = rate;
    const avPlayer = this.player;
    if (avPlayer === null) {
      return; // 未就绪:意图已落账,prepared 回调兜
    }
    const state = avPlayer.state;
    const inPlayback = state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed';
    if (!inPlayback) {
      return;
    }
    try {
      if (playing) {
        this.applyRate(avPlayer);
        avPlayer.play().catch((_e: Object) => {
          // 错误经 error 事件出
        });
      } else {
        avPlayer.pause().catch((_e: Object) => {});
      }
    } catch (_) {
      // 状态机竞态:尽力而为
    }
  }

  /** 通道 viewStatus:位置/时长(秒)与是否在播。 */
  status(): Record<string, Object> {
    const avPlayer = this.player;
    if (avPlayer === null || this.released) {
      const idle: Record<string, Object> = {
        'position': 0, 'duration': 0, 'playing': false,
      };
      return idle;
    }
    let positionMs = 0;
    let durationMs = 0;
    try {
      positionMs = avPlayer.currentTime;
    } catch (_) {
      // idle/initialized 无时长:按 0
    }
    try {
      durationMs = avPlayer.duration;
    } catch (_) {
      // 同上
    }
    const map: Record<string, Object> = {
      'position': positionMs / 1000.0,
      'duration': durationMs / 1000.0,
      'playing': avPlayer.state === 'playing',
    };
    return map;
  }

  /** 通道 viewSeek:定位(秒)。 */
  seek(positionSec: number): void {
    const avPlayer = this.player;
    if (avPlayer === null) {
      return;
    }
    const state = avPlayer.state;
    const seekable = state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed';
    if (!seekable) {
      return;
    }
    try {
      avPlayer.seek(Math.floor(positionSec * 1000),
        media.SeekMode.SEEK_PREV_SYNC);
    } catch (_) {
      // 尽力而为
    }
  }

  /** 路径与面双就位才建播放器(两路时序不定)。 */
  private maybeStart(): void {
    if (this.released || this.player !== null) {
      return;
    }
    if (this.path === '' || this.surfaceId === '') {
      return;
    }
    this.startPlayer();
  }

  private async startPlayer(): Promise<void> {
    try {
      this.file = fs.openSync(this.path, fs.OpenMode.READ_ONLY);
      const avPlayer = await media.createAVPlayer();
      if (this.released) {
        await avPlayer.release(); // dispose 竞态:直接回收
        return;
      }
      this.player = avPlayer;
      // 先挂满回调再 fdSrc(idle→initialized 异步落地;surfaceId 只能
      // 在 'initialized' 回调设 —— VideoSheet 5400102 同款教训)。
      avPlayer.on('stateChange', (state: string): void => {
        if (this.released) {
          return;
        }
        if (state === 'initialized') {
          avPlayer.surfaceId = this.surfaceId;
          this.surfaceBound = true;
          avPlayer.prepare().catch((_e: Object) => {
            // 错误经 error 事件出
          });
        } else if (state === 'prepared') {
          this.applyRate(avPlayer);
          if (this.playingIntent) {
            avPlayer.play().catch((_e: Object) => {});
          }
        } else if (state === 'error') {
          Log.w(TAG, `view ${this.viewId} error 态`);
        }
      });
      avPlayer.on('error', (err: Object): void => {
        Log.w(TAG, `view ${this.viewId} error:${JSON.stringify(err)}`);
      });
      avPlayer.on('videoSizeChange', (width: number, height: number): void => {
        if (width > 0 && height > 0) {
          this.faceComponent?.setAspect(width / height);
        }
      });
      avPlayer.fdSrc = { fd: this.file.fd };
    } catch (err) {
      Log.w(TAG, `装载失败:${JSON.stringify(err)}`);
    }
  }

  /** 速率/静音:setSpeed 仅 prepared 及之后可调;非 1 速率静音。 */
  private applyRate(avPlayer: media.AVPlayer): void {
    const speed = resolveSpeed(this.rateIntent);
    try {
      if (speed !== media.PlaybackSpeed.SPEED_FORWARD_1_00_X) {
        avPlayer.setSpeed(speed);
        avPlayer.setVolume(0);
      } else {
        avPlayer.setVolume(1);
      }
    } catch (_) {
      // 状态未到:prepared 回调再兜
    }
  }
}

/** 面组件:XComponent surface,onLoad 回投 surfaceId,宽高比可变。 */
@Component
struct VideoViewFace {
  view: VideoViewPlatformView | null = null;
  @State aspect: number = 0; // 0 = 未定,铺满;定了按比例收进
  private controller: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.view?.attachFace(this); // 挂回实例:videoSizeChange 驱动宽高比
  }

  aboutToDisappear(): void {
    this.view?.dispose(); // 面随层销毁 = 视图销毁(引擎 dispose 路兜底,幂等)
  }

  setAspect(aspect: number): void {
    this.aspect = aspect;
  }

  build() {
    Stack() {
      XComponent({
        id: `np-video-${this.view?.viewId ?? 0}`,
        type: 'surface',
        controller: this.controller,
      })
        .width('100%')
        .height('100%')
        .aspectRatio(this.aspect > 0 ? this.aspect : undefined)
        .onLoad((_event?: object): void => {
          this.view?.onSurfaceReady(this.controller);
        })
    }
    .width('100%')
    .height('100%')
  }
}

/** 引擎入口 builder:Params.platformView 转本文件实例。 */
@Builder
export function buildVideoView(params: Params) {
  VideoViewFace({ view: params.platformView as VideoViewPlatformView })
}
