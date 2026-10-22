/**
 * 全屏视频播放覆盖层(Index.ets Stack 顶层,SaveSheet 同款挂法)。
 *
 * 黑底全屏 + XComponent 视频面(按视频宽高比居中收进,letterbox)+
 * 左上关闭钮(关闭 = finish → VideoSession.close() → 通道 result
 * 交付)。播放器 = @ohos.multimedia.media AVPlayer(API 23 形态:
 * setSpeed 预设档、无 playbackComplete 事件 —— 播完走 stateChange
 * 'completed'):
 * - 生命周期:aboutToAppear 建 AVPlayer(fdSrc 打开档案 → surfaceId
 *   → prepare → play);aboutToDisappear 释放(XComponent 随层销毁,
 *   surface 先摘再释放);
 * - 画面宽高比:videoSizeChange 事件(@State aspect)驱动,横竖皆收进;
 * - 出错 → Log + close(通道结果已是 success 契约,错误不打断 ——
 *   ohos 播放错误常见于编码不支持,直接收口)。
 */
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import { Log } from '@ohos/flutter_ohos';
import { VideoSession } from './VideoSession';

const TAG = 'VideoSheet';

@Component
export struct VideoSheet {
  @State aspect: number = 16 / 9;
  private controller: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;
  private pendingSurfaceId: string = '';
  private surfaceBound = false;

  aboutToAppear(): void {
    this.startPlayer();
  }

  aboutToDisappear(): void {
    this.stopPlayer();
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
      avPlayer.fdSrc = { fd: this.file.fd };
      if (this.pendingSurfaceId !== '') {
        avPlayer.surfaceId = this.pendingSurfaceId;
        this.surfaceBound = true;
      }
      // 速率:预设档就近(0.4 顺帧 → 0.5);非 1 静音(契约同
      // iOS/Android —— 变速下音轨无意义)
      if (request.rate !== 1) {
        let target = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
        if (request.rate < 0.6) {
          target = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
        } else if (request.rate < 1) {
          target = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
        } else if (request.rate <= 1.5) {
          target = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
        } else if (request.rate <= 1.9) {
          target = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
        } else {
          target = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
        }
        avPlayer.setSpeed(target);
        avPlayer.setVolume(0);
      }
      avPlayer.on('videoSizeChange', (width: number, height: number): void => {
        if (width > 0 && height > 0) {
          this.aspect = width / height;
        }
      });
      avPlayer.on('stateChange', (state: string): void => {
        if (state === 'completed') {
          Log.i(TAG, '播放完成');
          VideoSession.close();
        } else if (state === 'error') {
          Log.w(TAG, 'AVPlayer error 态,收口');
          VideoSession.close();
        }
      });
      avPlayer.on('error', (err: Object): void => {
        Log.w(TAG, `AVPlayer error:${JSON.stringify(err)}`);
        VideoSession.close();
      });
      avPlayer.prepare();
      avPlayer.play();
    } catch (err) {
      Log.w(TAG, `起播失败:${JSON.stringify(err)}`);
      VideoSession.close();
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
        // 摘面尽力而为(层已销毁时可能报错)
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
        id: 'zpill-video',
        type: 'surface',
        controller: this.controller,
      })
        .width('100%')
        .height('100%')
        .aspectRatio(this.aspect)
        .onLoad((_event?: object): void => {
          const surfaceId = this.controller.getXComponentSurfaceId();
          if (surfaceId !== '') {
            this.pendingSurfaceId = surfaceId;
            if (this.player !== null) {
              this.player.surfaceId = surfaceId;
              this.surfaceBound = true;
            }
          }
        })
      // 左上关闭钮(iOS AVKit / Android VideoActivity 同位同语义)
      Row() {
        Text('✕')
          .fontSize(22)
          .fontColor('#FFFFFF')
          .padding(14)
          .onClick((): void => {
            VideoSession.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height('100%')
  }
}
