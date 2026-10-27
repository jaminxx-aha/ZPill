/**
 * ZPill 视频 LUT 导出通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/video_lut_export.dart(MethodChannel
 * `zpill/video_lut`):重活在 rawdecoder.so 的 C++ 管线
 * (cpp/video_lut.cpp:解封装 → 硬解 NV12 → CPU 行并行 3D-LUT →
 * 硬编 H.264 → 混流,音频直通)。
 *
 * - `isSupported`:真身已注册即 true(通道注册本身即探测,iOS 同义);
 * - `export({path, cube(Float32Array), size})`:临时产物落在应用
 *   cacheDir(命名对齐 iOS lut_export_<ts>.mp4),**落库不归本层**
 *   (Dart 走 GallerySaver.importFiles);进度由本侧 250ms 轮询 napi
 *   `lutProgress` 后经通道 `onProgress` 反向调用(契约同 iOS);
 * - `cancel`:napi `lutCancel` 原子位,导出以 cancelled 收场
 *   (PlatformException code:cancelled,Dart 按取消提示)。
 */
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';
import rawdecoder from 'librawdecoder.so';

const TAG = 'VideoLutExportPlugin';
const CHANNEL = 'zpill/video_lut';

/** rawdecoder.so 人设(LUT 三方法,见 cpp/video_lut.cpp)。 */
interface LutNapi {
  lutExportVideo(path: string, outPath: string, cube: Float32Array,
    size: number): Promise<string>;
  lutProgress(): number;
  lutCancel(): void;
}

const lutNapi = rawdecoder as LutNapi;

export class VideoLutExportPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private cacheDir: string = '';
  private pollTimer: number = -1;

  getUniqueClassName(): string {
    return 'VideoLutExportPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    const context = binding.getApplicationContext();
    this.cacheDir = `${context.cacheDir}`;
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.stopPolling();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'isSupported') {
      result.success(true);
      return;
    }
    if (call.method === 'export') {
      const path = call.argument('path') as string | null;
      const size = (call.argument('size') as number) ?? 0;
      const cube = call.argument('cube') as Float32Array | null;
      if (path === null || path === undefined || path.length === 0 ||
        cube === null || size < 2) {
        result.error('bad_args', 'path/size/cube 缺失或非法', null);
        return;
      }
      const out =
        `${this.cacheDir}/lut_export_${Date.now()}.mp4`;
      Log.w(TAG, `lut export: cube elements=${cube.length} size=${size}`);
      // 进度轮询:250ms 一拍(契约节奏),经通道 onProgress 反推 Dart。
      this.startPolling();
      lutNapi.lutExportVideo(path, out, cube, size).then((outPath) => {
        this.stopPolling();
        result.success(outPath);
      }).catch((err: Error) => {
        this.stopPolling();
        Log.w(TAG, `lut export failed:${err.message}`);
        const cancelled = err.message.includes('cancelled');
        result.error(cancelled ? 'cancelled' : 'export_failed',
          err.message, null);
      });
      return;
    }
    if (call.method === 'cancel') {
      lutNapi.lutCancel();
      result.success(null);
      return;
    }
    result.notImplemented();
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollTimer = setInterval((): void => {
      const p = lutNapi.lutProgress();
      this.channel?.invokeMethod('onProgress', p, null);
    }, 250);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }
}
