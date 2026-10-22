/**
 * ZPill 后台长时任务保活(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/background_transfer.dart(MethodChannel
 * `zpill/bg`):`ensureRunning`(携 `modes: string[]`)/ `stop`。
 * Dart 协调器把各业务持有者(传输 dataTransfer / BLE 会话
 * bluetoothInteraction [+ location,GPS 注入采样期])折成模式并集,只在
 * 并集变化沿过通道;native 本类做薄执行:
 *
 * - 申请:string[] 重载 startBackgroundRunning(context, modes[], wantAgent)
 *   (API 12+,DevEco SDK d.ts 实证;单值枚举重载一次只收一个模式,
 *   `BLUETOOTH_INTERACTION | LOCATION` = 7 不是合法枚举值);
 * - 换装:已在运行 → updateBackgroundRunning(context, modes[]) 原地
 *   增删模式,不拆任务;
 * - 状态机:desired(最近意图,latest-wins)+ running/cacheModes(系统态
 *   认知)。每个请求 generation++,异步落地沿比对代际:update 落地过期
 *   则不写模式缓存(防旧值污染);start 落地是系统真相,过期也先同步
 *   认知再由 settle() 向最新意图收敛(stop → 回收;换集 → update 原地
 *   对齐)—— 防「ensure 在途时 stop 进来 → start 落地把 flag 翻回
 *   true 后无人回收」的泄漏态(HarmoNiLink 代际闸口径的收敛强化);
 * - 错码表(9800005 = Continuous task verification failed):
 *   · start 报 9800005:「已申请」—— 系统仍持有(如挂起后自动恢复),
 *     按成功收场:running=true、模式缓存清空,后续 settle 用 update 对齐;
 *   · update 报 9800005:系统侧任务已不在 —— 判静默吊销:running=false
 *     留痕,settle 自愈重申请;
 *   · stop 报 9800005:「未在运行」—— 判静默吊销留痕(flag 已同步),
 *     下次 ensure 正常重申请;
 *   · 13400002(非前台申请,2026-10-05 实证口径)及其余错码:降级为
 *     「仅前台传输」留痕,不报错给 Dart,等下次请求/回前台重申再试。
 * - continuousTaskCancel 监听(API 15+,compat 18 内):系统主动吊销
 *   (如 location 挂着不采样)沿同步 running=false 留痕,不在此原地对撞
 *   重申请 —— 回前台沿 Dart 侧 reassert 驱动(冻结期回调可能不送达,
 *   stop/update 的 9800005 推断是兜底)。continuousTaskSuspend 事件
 *   @since 20 超 compat,不用。
 */
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { BusinessError } from '@kit.BasicServicesKit';
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

/// module.json5 backgroundModes 已声明的全集(native 侧白名单,防未声明
/// 模式让整次系统调用 401 全灭)。
const KNOWN_MODES: string[] = ['dataTransfer', 'bluetoothInteraction', 'location'];

/// cancel 监听是模块级单注册(重复 on() 报 401),引擎重挂沿只注册一次。
let cancelListenerRegistered = false;

/** `zpill/bg` 通道实现。 */
export class BgPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private context: common.Context | null = null;
  private ability: UIAbility | null = null;

  /// 代际闸:每个通道请求 ++;在途异步操作的落地沿比对,过期不写认知
  /// (新请求已接管意图),由 settle() 按最新意图续收敛。
  private generation = 0;
  /// 最近一次请求的模式并集(latest-wins;空 = 停)。
  private desired: string[] = [];
  /// 系统态认知:长时任务在跑 + 当前持有的模式集。
  private running = false;
  private cacheModes: string[] = [];
  /// start 异步在途闸:防并发双发(第二发必吃 9800005),在途期新请求
  /// 只更新 desired,落地沿 settle() 续。
  private startInFlight = false;

  getUniqueClassName(): string {
    return 'BgPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'zpill/bg');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    this.registerCancelListener();
  }

  /// 系统静默吊销监听(API 15+):cancel 沿任务与通知都被系统收回,
  /// 同步认知 + 留痕;不原地对撞重申请(cancel 的动因多是「模式未使用」,
  /// 立刻原样重申会再被吊销),回前台沿 Dart reassert 再走。
  private registerCancelListener(): void {
    if (cancelListenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on(
        'continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          Log.w(TAG, `系统吊销长时任务(reason=${info.reason} id=${info.id})—— 同步认知`);
          this.running = false;
          this.cacheModes = [];
        });
      cancelListenerRegistered = true;
    } catch (e) {
      Log.w(TAG, `continuousTaskCancel on() fail: ${e}`);
    }
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
        this.requestEnsure(this.parseModes(call), result);
        break;
      case 'stop':
        this.requestStop(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// modes 参数解析:白名单过滤 + 去重排序(与 cacheModes 可比);
  /// 旧调用(无参)回落 dataTransfer。
  private parseModes(call: MethodCall): string[] {
    const raw = call.argument('modes') as string[] ?? ['dataTransfer'];
    const filtered = raw.filter((m: string): boolean => KNOWN_MODES.includes(m));
    if (filtered.length !== raw.length) {
      Log.w(TAG, `忽略未声明模式: ${raw.join(',')}`);
    }
    return Array.from(new Set(filtered)).sort();
  }

  /// Context 取用:长时任务文档示例用 UIAbility context,兜底 app context。
  private ctx(): common.Context | null {
    return this.ability?.context ?? this.context ?? null;
  }

  private requestEnsure(modes: string[], result: MethodResult): void {
    this.generation++;
    this.desired = modes;
    // 契约:不阻塞 Dart(失败降级不炸通道)。
    result.success(null);
    if (this.startInFlight) {
      return; // 在途 start 落地沿 settle() 按最新 desired 续
    }
    if (this.running) {
      // 每次 ensure 都过一遍 update:对系统态做一次真实校验(静默吊销
      // 自愈路);任务健在同集只是无感对齐。
      this.updateSystem();
      return;
    }
    this.startSystem();
  }

  private requestStop(result: MethodResult): void {
    this.generation++;
    this.desired = [];
    const wasRunning = this.running;
    // 认知先行同步(在途 start 的落地沿按代际弃写)。
    this.running = false;
    this.cacheModes = [];
    result.success(null);
    if (wasRunning) {
      this.stopSystem();
    }
  }

  /// 认知 → 意图收敛(异步落地后的续;与 requestEnsure 的差别只在
  /// 「同集即静默」—— 终止条件,防 落地→settle→update→落地 死循环)。
  private settle(): void {
    if (this.startInFlight) {
      return;
    }
    const want = this.desired;
    if (want.length === 0) {
      if (this.running) {
        this.running = false;
        this.cacheModes = [];
        this.stopSystem();
      }
      return;
    }
    if (this.running) {
      if (!this.sameModes(want)) {
        this.updateSystem();
      }
      return;
    }
    this.startSystem();
  }

  private sameModes(modes: string[]): boolean {
    if (modes.length !== this.cacheModes.length) {
      return false;
    }
    for (let i = 0; i < modes.length; i++) {
      if (modes[i] !== this.cacheModes[i]) {
        return false;
      }
    }
    return true;
  }

  private startSystem(): void {
    const ctx = this.ctx();
    const bundleName = this.ability?.context.abilityInfo.bundleName ?? '';
    if (ctx === null || bundleName.length === 0) {
      Log.w(TAG, 'startSystem: context 未就绪,按仅前台传输降级');
      return;
    }
    const modes: string[] = this.desired;
    const gen = this.generation;
    this.startInFlight = true;
    const want: Want = { bundleName: bundleName, abilityName: 'EntryAbility' };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent): void => {
        backgroundTaskManager
          .startBackgroundRunning(ctx, modes, agent)
          .then((): void => {
            this.startInFlight = false;
            // 落地即系统真相:无论代际是否过期都先同步认知(弃写会漏 ——
            // 若新意图是 stop,刚落地的任务将无人回收),再由 settle() 按
            // 最新意图收敛(stop → 回收;换集 → update 原地对齐)。
            if (gen !== this.generation) {
              Log.w(TAG, `start 落地即过期(gen ${gen})—— 真相先同步,意图后收敛`);
            }
            this.running = true;
            this.cacheModes = modes;
            Log.i(TAG, `长时任务已申请(${modes.join('+')})`);
            this.settle();
          })
          .catch((e: Object): void => {
            this.startInFlight = false;
            const be = e as BusinessError;
            if (be.code === 9800005) {
              // 「已申请」:系统仍持有(如挂起后自动恢复)—— 按成功收场,
              // 模式缓存清空让 settle 用 update 对齐真实模式。
              Log.i(TAG, 'start 9800005 已申请 —— 同步认知待对齐');
              this.running = true;
              this.cacheModes = [];
              this.settle();
              return;
            }
            // 13400002(非前台申请)及其余:降级仅前台,不重试(防错态
            // 死循环),下次请求/回前台重申再试。
            Log.w(TAG, `startBackgroundRunning ${be.code}: ${be.message} —— 降级仅前台`);
          });
      })
      .catch((e: Object): void => {
        this.startInFlight = false;
        Log.w(TAG, `getWantAgent fail: ${e}`);
      });
  }

  private updateSystem(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      Log.w(TAG, 'updateSystem: context 未就绪,跳过');
      return;
    }
    const modes: string[] = this.desired;
    const gen = this.generation;
    backgroundTaskManager
      .updateBackgroundRunning(ctx, modes)
      .then((): void => {
        if (gen === this.generation) {
          this.cacheModes = modes;
          Log.i(TAG, `长时任务模式换装 → ${modes.join('+')}`);
        } else {
          Log.w(TAG, `update 落地即过期(gen ${gen}),不写认知`);
        }
        this.settle();
      })
      .catch((e: Object): void => {
        const be = e as BusinessError;
        if (be.code === 9800005) {
          // 系统侧任务已不在(静默吊销):认知归零留痕,settle 自愈重申请。
          Log.w(TAG, `update 9800005: ${be.message} —— 判静默吊销,自愈重申请`);
          this.running = false;
          this.cacheModes = [];
          this.settle();
          return;
        }
        Log.w(TAG, `updateBackgroundRunning ${be.code}: ${be.message} —— 降级维持现模式`);
      });
  }

  private stopSystem(): void {
    const ctx = this.ctx();
    if (ctx === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(ctx)
      .then((): void => {
        Log.i(TAG, '长时任务已释放');
      })
      .catch((e: Object): void => {
        const be = e as BusinessError;
        if (be.code === 9800005) {
          // 「未在运行」:本地此前认为在跑 —— 系统静默吊销实锤,留痕
          // (flag 已在请求沿同步为 false,下次 ensure 正常重申请)。
          Log.w(TAG, `stop 9800005: ${be.message} —— 系统侧早已不在(静默吊销)`);
          return;
        }
        Log.w(TAG, `stopBackgroundRunning ${be.code}: ${be.message}`);
      });
  }
}
