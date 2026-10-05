/**
 * NikonPill 后台传输保活(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/background_transfer.dart(MethodChannel
 * `nikonpill/bg`):`ensureRunning` / `stop`,native 幂等。队列非空期间
 * 申请 DATA_TRANSFER 长时任务,清空即释放;系统自动挂常驻通知。
 *
 * ohos API 要点(@ohos.resourceschedule.backgroundTaskManager):
 * - 前置:module.json5 里 ability 声明 "backgroundModes": ["dataTransfer"]
 *   + requestPermissions 加 ohos.permission.KEEP_BACKGROUND_RUNNING;
 * - startBackgroundRunning(context, BackgroundMode.DATA_TRANSFER, wantAgent)
 *   的 wantAgent 只用于「点通知拉起哪个 ability」;
 * - 任一步失败(如非前台申请 13400002)不报错给 Dart —— 按契约降级为
 *   「仅前台传输」,hilog 留痕。
 */
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
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

const TAG = 'BgPlugin';

/** `nikonpill/bg` 通道实现。 */
export class BgPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private ability: UIAbility | null = null;
  private running = false;

  getUniqueClassName(): string {
    return 'BgPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/bg');
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
      case 'ensureRunning':
        this.ensureRunning(result);
        break;
      case 'stop':
        this.stop(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// Context 取用:长时任务文档示例用 UIAbility context,兜底 app context。
  private ctx(): common.Context | null {
    return this.ability?.context ?? this.context ?? null;
  }

  private ensureRunning(result: MethodResult): void {
    if (this.running) {
      result.success(null);
      return;
    }
    const ctx = this.ctx();
    const bundleName = this.ability?.context.abilityInfo.bundleName ?? '';
    if (ctx === null || bundleName.length === 0) {
      Log.w(TAG, 'ensureRunning: context 未就绪,按仅前台传输降级');
      result.success(null);
      return;
    }
    const want: Want = { bundleName: bundleName, abilityName: 'EntryAbility' };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent): void => {
        backgroundTaskManager
          .startBackgroundRunning(
            ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent)
          .then((): void => {
            this.running = true;
            result.success(null);
          })
          .catch((e: Object): void => {
            Log.e(TAG, `startBackgroundRunning: ${e}`);
            result.success(null);
          });
      })
      .catch((e: Object): void => {
        Log.e(TAG, `getWantAgent: ${e}`);
        result.success(null);
      });
  }

  private stop(result: MethodResult): void {
    if (!this.running) {
      result.success(null);
      return;
    }
    const ctx = this.ctx();
    this.running = false;
    if (ctx === null) {
      result.success(null);
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(ctx)
      .then((): void => {
        result.success(null);
      })
      .catch((e: Object): void => {
        Log.w(TAG, `stopBackgroundRunning: ${e}`);
        result.success(null);
      });
  }
}
