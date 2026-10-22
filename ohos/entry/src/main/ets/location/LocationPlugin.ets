/**
 * ZPill 位置采样(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/location_host.dart:
 * - MethodChannel `zpill/location` 的 `current` 单次定位 →
 *   [latitude, longitude](WGS84 十进制度);未授权/不可用/超时 → null。
 * - `startStream`/`stopStream` + EventChannel `zpill/location/stream`
 *   连续定位流(BLE GPS 注入驱动源):on('locationChange') 持续回调,
 *   事件载荷 Map{latitude, longitude, altitude}。
 * - `authStatus` 回授权态(granted/denied,查 token);`requestAlways`
 *   在 ohos 即前景定位授权(真正的后台定位须受限 ACL 权限
 *   ohos.permission.LOCATION_IN_BACKGROUND,普通应用拿不到 —— app 退
 *   后台时流会停,与 iOS「使用期间」同限,如实降级)。
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
import bundleManager from '@ohos.bundle.bundleManager';
import geoLocationManager from '@ohos.geoLocationManager';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  AbilityAware,
  AbilityPluginBinding,
  EventChannel,
  EventSink,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';

const TAG = 'LocationPlugin';

/// 单次定位兜底超时(与 Dart 侧 8s 单飞对齐;真机核对实际时延)。
const LOCATE_TIMEOUT_MS = 8000;

/** `zpill/location` + `zpill/location/stream` 通道实现。 */
export class LocationPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private streaming = false;
  private ability: UIAbility | null = null;

  getUniqueClassName(): string {
    return 'LocationPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel =
      new MethodChannel(binding.getBinaryMessenger(), 'zpill/location');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    this.events = new EventChannel(
      binding.getBinaryMessenger(), 'zpill/location/stream');
    this.events.setStreamHandler({
      onListen: (args: ESObject, events: EventSink): void => {
        this.sink = events;
      },
      onCancel: (args: ESObject): void => {
        this.sink = null;
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.events?.setStreamHandler(null);
    this.events = null;
    this.sink = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
  }

  onDetachedFromAbility(): void {
    this.ability = null;
  }

  // ------------------------------------------------------------------
  // MethodChannel
  // ------------------------------------------------------------------

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'current':
        this.current(result);
        break;
      case 'startStream':
        this.startStream(result);
        break;
      case 'stopStream':
        this.stopStream();
        result.success(null);
        break;
      case 'requestAlways':
        // ohos 无「始终」分层:同前景授权(差异见类注)
        this.current(result);
        break;
      case 'authStatus':
        this.authStatus((s: string): void => {
          result.success(s);
        });
        break;
      default:
        result.notImplemented();
    }
  }

  /** 查定位授权(granted/denied;读 token,不弹窗;checkAccessToken 异步)。 */
  private authStatus(onDone: (s: string) => void): void {
    try {
      const flag = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
      const info = bundleManager.getBundleInfoForSelfSync(flag);
      const tokenId = info.appInfo.accessTokenId;
      const atManager = abilityAccessCtrl.createAtManager();
      Promise.all([
        atManager.checkAccessToken(tokenId,
          'ohos.permission.APPROXIMATELY_LOCATION'),
        atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION'),
      ]).then((rs: abilityAccessCtrl.GrantStatus[]): void => {
        const granted = rs.every((s: abilityAccessCtrl.GrantStatus): boolean =>
          s === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
        onDone(granted ? 'granted' : 'denied');
      }).catch((e: Object): void => {
        Log.w(TAG, `authStatus: ${e}`);
        onDone('denied');
      });
    } catch (e) {
      Log.w(TAG, `authStatus: ${e}`);
      onDone('denied');
    }
  }

  private startStream(result: MethodResult): void {
    const ctx = this.ability?.context ?? null;
    if (ctx === null) {
      result.error('noAbility', 'UIAbility 未挂载', null);
      return;
    }
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(ctx,
      ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'])
      .then((res: PermissionRequestResult): void => {
        for (const status of res.authResults) {
          if (status !== 0) {
            result.error('permissionDenied', '定位权限未授权', null);
            return;
          }
        }
        if (this.streaming) {
          result.success(null);
          return;
        }
        try {
          const request: geoLocationManager.ContinuousLocationRequest = {
            interval: 1, // 秒;注入节流在 Dart 会话层
            locationScenario: geoLocationManager.UserActivityScenario.NAVIGATION,
          };
          geoLocationManager.on('locationChange', request,
            (loc: geoLocationManager.Location): void => {
              this.sink?.success({
                'latitude': loc.latitude,
                'longitude': loc.longitude,
                'altitude': loc.altitude,
              });
            });
          this.streaming = true;
          result.success(null);
        } catch (e) {
          Log.e(TAG, `locationChange on: ${e}`);
          result.error('streamFailed', `${e}`, null);
        }
      })
      .catch((e: Object): void => {
        Log.w(TAG, `requestPermissionsFromUser: ${e}`);
        result.error('permissionDenied', `${e}`, null);
      });
  }

  private stopStream(): void {
    if (!this.streaming) {
      return;
    }
    try {
      geoLocationManager.off('locationChange');
    } catch (e) {
      Log.w(TAG, `locationChange off: ${e}`);
    }
    this.streaming = false;
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
