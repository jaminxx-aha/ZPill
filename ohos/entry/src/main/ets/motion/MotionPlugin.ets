/**
 * ZPill 水平仪姿态(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/motion_host.dart(EventChannel
 * `zpill/motion/attitude`):每条事件 = [pitch, roll](弧度,pitch
 * 抬头为正,roll 右倾为正)。
 *
 * ohos API 要点(@ohos.sensor,API 9+):
 * - SensorId.GRAVITY(257)免权限;
 * - on(type, callback, options) 的 options.interval 支持 SensorFrequency
 *   字面量('game' ≈ 50Hz / 'ui' / 'normal'),监看平滑度对齐 iOS 侧 30Hz
 *   取 'game'(实际到达率待真机核对);
 * - off(type) 不带 callback = 摘除该类型全部监听。
 *
 * 公式(与 iOS MotionPlugin.swift 同一物理约定,符号相反):
 * @ohos.sensor 重力 = **施加在设备上的力**(m/s²),平放屏幕朝上 =
 * (0, 0, +9.8);iOS CMDeviceMotion.gravity = 重力拉拽方向,平放 =
 * (0, 0, -1)。两者反号,故:
 *   pitch = atan2(-z, y)(抬头为正;平放屏幕朝上 = -π/2,即镜头朝地)
 *   roll  = atan2(-x, y)(右倾为正)
 * 物理核对:平放 (0,0,9.8) → pitch=-π/2, roll=0;竖起屏幕朝人
 * (0,9.8,0) → pitch=0;右倾 90° (-9.8,0,0) → roll=+π/2。
 * 轴系/符号与真机核对后如有出入只改这里(待真机核对)。
 */
import sensor from '@ohos.sensor';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  EventChannel,
  EventSink,
  Log,
} from '@ohos/flutter_ohos';

const TAG = 'MotionPlugin';

/** `zpill/motion/attitude` 通道实现。 */
export class MotionPlugin implements FlutterPlugin {
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private listening = false;

  getUniqueClassName(): string {
    return 'MotionPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.events =
      new EventChannel(binding.getBinaryMessenger(), 'zpill/motion/attitude');
    this.events.setStreamHandler({
      onListen: (args: ESObject, events: EventSink): void => {
        this.sink = events;
        this.startSensor();
      },
      onCancel: (): void => {
        this.stopSensor();
        this.sink = null;
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.stopSensor();
    this.sink = null;
    this.events = null;
  }

  private startSensor(): void {
    if (this.listening) {
      return;
    }
    try {
      const options: sensor.Options = { interval: 'game' };
      sensor.on(sensor.SensorId.GRAVITY, (data: sensor.GravityResponse): void => {
        this.emit(data);
      }, options);
      this.listening = true;
    } catch (e) {
      // 无重力传感器等:发错误事件,Dart 侧按「水平仪不可用」降级
      Log.e(TAG, `sensor.on GRAVITY: ${e}`);
      const sink = this.sink;
      if (sink !== null) {
        sink.error('motion_unavailable', `${e}`, null);
      }
    }
  }

  private stopSensor(): void {
    if (!this.listening) {
      return;
    }
    this.listening = false;
    try {
      sensor.off(sensor.SensorId.GRAVITY);
    } catch (e) {
      Log.w(TAG, `sensor.off GRAVITY: ${e}`);
    }
  }

  private emit(data: sensor.GravityResponse): void {
    const sink = this.sink;
    if (sink === null) {
      return;
    }
    const pitch = Math.atan2(-data.z, data.y);
    const roll = Math.atan2(-data.x, data.y);
    sink.success([pitch, roll]);
  }
}
