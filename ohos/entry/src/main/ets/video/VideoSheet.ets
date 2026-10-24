/**
 * 全屏视频播放覆盖层(Index.ets Stack 顶层,SaveSheet 同款挂法)。
 *
 * 黑底全屏 + XComponent 视频面(按视频宽高比居中收进,letterbox)+
 * 点按面切换播放/暂停 + 左上关闭钮(关闭 = VideoSession.close(pos) →
 * 通道 result 交付**关闭时刻位置**,Dart 侧续播用)。
 *
 * **挖孔避让**(2026-10-24 真机实锤):横屏时挖孔相机落在左缘
 * (cutoutPosition: left),✕ 钉死左上会被物理遮挡(不可见不可点)——
 * 关闭钮的 padding 按 CUTOUT avoid area 现算(leftRect/topRect 右下缘),
 * aboutToAppear 与 XComponent onLoad 各查一次(转横后 onLoad 时序更靠
 * 后,避免横转未稳的陈旧值)。播放器 = @ohos.multimedia.media AVPlayer
 * (API 23 形态:setSpeed 预设档、无 playbackComplete 事件 —— 播完走
 * stateChange 'completed'):
 * - 生命周期:起播由 XComponent onLoad 触发(面就位才建播放器)。状态机
 *   驱动:先挂满回调再设 fdSrc(idle→initialized **异步落地**,surfaceId
 *   跟在 fdSrc 后直设 = 还在 idle,5400102 实锤);stateChange
 *   'initialized' 设 surfaceId(仅此态可设)→ prepare;'prepared' 速率/
 *   静音(setSpeed 仅 prepared 及之后可调)→ **续播 seek**(position >
   *  0.5s 才 seek)→ play。aboutToDisappear 释放(XComponent 随层销毁,
 *   surface 先摘再释放);
 * - 画面宽高比:videoSizeChange 事件(@State aspect)驱动,横竖皆收进;
 * - 出错 → Log + close(null)(通道结果已是 success 契约,错误不打断
 *   —— ohos 播放错误常见于编码不支持,直接收口)。
 */
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import { Log } from '@ohos/flutter_ohos';
import { VideoSession } from './VideoSession';

const TAG = 'VideoSheet';
/** 续播门槛:起播位置小于此值(秒)直接从头,不值得 seek。 */
const RESUME_MIN_SEC = 0.5;

@Component
export struct VideoSheet {
  @State aspect: number = 16 / 9;
  @State cutoutLeftVp: number = 0;
  @State cutoutTopVp: number = 0;
  private controller: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;
  private pendingSurfaceId: string = '';
  private surfaceBound = false;
  private started = false; // onLoad 幂等闸:防双建播放器

  aboutToAppear(): void {
    this.queryCutout();
  }

  aboutToDisappear(): void {
    this.stopPlayer();
  }

  /** 挖孔避让区(当前方向):✕ 钮 padding 依此推离物理遮挡区。 */
  private queryCutout(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined || context === null) {
      return;
    }
    window.getLastWindow(context).then((w: window.Window): void => {
      const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      this.cutoutTopVp = px2vp(area.topRect.top + area.topRect.height);
      this.cutoutLeftVp = px2vp(area.leftRect.left + area.leftRect.width);
    }).catch((_e: Object): void => {
      // 拿不到按 0(✕ 回左上角,遮挡机型上仍有点按面兜底)
    });
  }

  /** 关闭时刻播放位置(秒);播放器不在场/拿不到 = null。 */
  private currentPositionSec(): number | null {
    const avPlayer = this.player;
    if (avPlayer === null) {
      return null;
    }
    try {
      return avPlayer.currentTime / 1000.0;
    } catch (_) {
      return null;
    }
  }

  /** 点按面:播放中暂停,暂停/prepared 续播,播完回零重放。 */
  private togglePlay(): void {
    const avPlayer = this.player;
    if (avPlayer === null) {
      return;
    }
    try {
      const state = avPlayer.state;
      if (state === 'playing') {
        avPlayer.pause().catch((_e: Object) => {});
      } else if (state === 'paused' || state === 'prepared') {
        avPlayer.play().catch((_e: Object) => {});
      } else if (state === 'completed') {
        avPlayer.seek(0, media.SeekMode.SEEK_PREV_SYNC);
        avPlayer.play().catch((_e: Object) => {});
      }
    } catch (_) {
      // 状态机竞态:尽力而为
    }
  }

  private async startPlayer(): Promise<void> {
    const request = VideoSession.current();
    if (request === null) {
      return;
    }
    try {
      this.file = fs.openSync(request.path, fs.OpenMode.READ_ONLY);
      const avPlayer = await media.createAVPlayer();
      this.player = avPlayer;
      // 速率档预解:预设档就近(0.4 顺帧 → 0.5);非 1 静音(契约同
      // iOS/Android —— 变速下音轨无意义)。
      let speed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
      if (request.rate < 0.6) {
        speed = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
      } else if (request.rate < 1) {
        speed = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
      } else if (request.rate > 1 && request.rate <= 1.5) {
        speed = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
      } else if (request.rate > 1.5 && request.rate <= 1.9) {
        speed = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
      } else if (request.rate > 1.9) {
        speed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
      }
      // 状态机驱动(**先挂满回调再设 fdSrc**,initialized 转变异步落地,
      // 不能跟在 fdSrc 后直设 surfaceId —— 5400102 实锤):
      // - 'initialized':设 surfaceId(仅此态可设)→ prepare;
      // - 'prepared':速率/静音(setSpeed 仅 prepared 及之后可调)→
      //   续播 seek → play。
      avPlayer.on('stateChange', (state: string): void => {
        if (state === 'initialized') {
          avPlayer.surfaceId = this.pendingSurfaceId;
          this.surfaceBound = true;
          avPlayer.prepare().catch((_e: Object) => {
            // 错误经 error 事件/stateChange 'error' 收口
          });
        } else if (state === 'prepared') {
          if (speed !== media.PlaybackSpeed.SPEED_FORWARD_1_00_X) {
            avPlayer.setSpeed(speed);
            avPlayer.setVolume(0);
          }
          if (request.position > RESUME_MIN_SEC) {
            avPlayer.seek(Math.floor(request.position * 1000),
              media.SeekMode.SEEK_PREV_SYNC);
          }
          avPlayer.play().catch((_e: Object) => {
            // 同上
          });
        } else if (state === 'completed') {
          Log.i(TAG, '播放完成');
          VideoSession.close(this.currentPositionSec());
        } else if (state === 'error') {
          Log.w(TAG, 'AVPlayer error 态,收口');
          VideoSession.close(null);
        }
      });
      avPlayer.on('error', (err: Object): void => {
        Log.w(TAG, `AVPlayer error:${JSON.stringify(err)}`);
        VideoSession.close(null);
      });
      avPlayer.on('videoSizeChange', (width: number, height: number): void => {
        if (width > 0 && height > 0) {
          this.aspect = width / height;
        }
      });
      avPlayer.fdSrc = { fd: this.file.fd };
    } catch (err) {
      Log.w(TAG, `起播失败:${JSON.stringify(err)}`);
      VideoSession.close(null);
    }
  }

  private stopPlayer(): void {
    const avPlayer = this.player;
    this.player = null;
    if (avPlayer !== null) {
      try {
        avPlayer.off('videoSizeChange');
        avPlayer.off('stateChange');
        avPlayer.off('error');
        if (this.surfaceBound) {
          avPlayer.surfaceId = '';
        }
      } catch (_) {
        // 摘面尽力而为(层已销毁时可能报错;空串 401 同属噪声)
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

  build() {
    Stack() {
      // 黑底全屏
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
      XComponent({
        id: 'nikonpill-video',
        type: 'surface',
        controller: this.controller,
      })
        .width('100%')
        .height('100%')
        .aspectRatio(this.aspect)
        .onLoad((_event?: object): void => {
          const surfaceId = this.controller.getXComponentSurfaceId();
          if (surfaceId !== '' && !this.started) {
            this.started = true;
            this.pendingSurfaceId = surfaceId;
            this.startPlayer(); // 面就位才起播(surfaceId 须 prepare 前设)
          }
          this.queryCutout(); // 转横后重查挖孔区(onLoad 时序在旋转稳后)
        })
      // 点按面:切换播放/暂停(XComponent 之上、✕ 之下,不挡关闭钮)
      Column()
        .width('100%')
        .height('100%')
        .onClick((): void => {
          this.togglePlay();
        })
      // 左上关闭钮(iOS AVKit / Android VideoActivity 同位同语义);
      // padding 按挖孔避让区推离物理遮挡(见头注)。
      Row() {
        Text('✕')
          .fontSize(22)
          .fontColor('#FFFFFF')
          .padding(14)
          .onClick((): void => {
            VideoSession.close(this.currentPositionSec());
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ top: this.cutoutTopVp, left: this.cutoutLeftVp })
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height('100%')
  }
}
