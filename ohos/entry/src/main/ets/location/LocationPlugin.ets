/**
 * NikonPill 位置采样(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/location_host.dart(MethodChannel
 * `nikonpill/location`):`current` 单次定位 → [latitude, longitude]
 * (WGS84 十进制度);未授权/不可用/超时 → null(不是错误,Dart 侧
 * 按「无位置」降级跳过 GPS 注入)。
 *
 * ohos API 要点(@ohos.abilityAccessCtrl + @ohos.geoLocationManager):
 * - 精确定位须同时授权 APPROXIMATELY_LOCATION + LOCATION(module.json5
 *   已带 reason/usedScene);仅模糊授权给 ~5km 粒度,对照片 GPS 是
 *   「错比缺糟」,一并按无定位降级;
 * - requestPermissionsFromUser 只收 UIAbilityContext(AbilityAware 拿
 *   UIAbility 引用;引擎早期未挂载 → null 降级);
 * - getCurrentLocation(CurrentLocationRequest) 一次定位,FIRST_FIX
 *   优先速度、timeoutMs 兜底,与 iOS 侧 8s 单飞超时对齐。
 */
import abilityAccessCtrl, { PermissionRequestResult } from '@ohos.abilityAccessCtrl';
import geoLocationManager from '@ohos.geoLocationManager';
import UIAbility from '@ohos.app.ability.UIAbility';
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

const TAG = 'LocationPlugin';

/// 单次定位兜底超时(与 Dart 侧 8s 单飞对齐;真机核对实际时延)。
const LOCATE_TIMEOUT_MS = 8000;

/** `nikonpill/location` 通道实现。 */
export class LocationPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private ability: UIAbility | null = null;

  getUniqueClassName(): string {
    return 'LocationPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel =
      new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/location');
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

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
  }

  onDetachedFromAbility(): void {
    this.ability = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'current') {
      this.current(result);
    } else {
      result.notImplemented();
    }
  }

  private current(result: MethodResult): void {
    const ctx = this.ability?.context ?? null;
    if (ctx === null) {
      Log.e(TAG, 'current: UIAbility 未挂载(AbilityAware 未回调)');
      result.success(null);
      return;
    }
    const atManager = abilityAccessCtrl.createAtManager();
    atManager
      .requestPermissionsFromUser(ctx,
        ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'])
      .then((res: PermissionRequestResult): void => {
        // authResults 与 permissionList 等长,0 = 已授权
        for (const status of res.authResults) {
          if (status !== 0) {
            result.success(null);
            return;
          }
        }
        const request: geoLocationManager.CurrentLocationRequest = {
          priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          timeoutMs: LOCATE_TIMEOUT_MS,
        };
        geoLocationManager.getCurrentLocation(request)
          .then((loc: geoLocationManager.Location): void => {
            result.success([loc.latitude, loc.longitude]);
          })
          .catch((e: Object): void => {
            Log.w(TAG, `getCurrentLocation: ${e}`);
            result.success(null);
          });
      })
      .catch((e: Object): void => {
        Log.w(TAG, `requestPermissionsFromUser: ${e}`);
        result.success(null);
      });
  }
}
