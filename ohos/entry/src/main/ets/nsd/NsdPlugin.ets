/**
 * NikonPill mDNS 相机发现(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/nsd_scanner.dart(`nikonpill/nsd` +
 * `nikonpill/nsd/events`):浏览 `_ptp._tcp` 并解析出 IP/端口/TXT,
 * found/lost 事件经 EventChannel 上报。
 *
 * ohos API 要点(@ohos.net.mdns,API 10+,DevEco 6.1.1 / apiVersion 24):
 * - 零 @permission 注解,module.json5 现有 INTERNET 即够;
 * - createDiscoveryService(context, serviceType) 建 DiscoveryService,
 *   on('serviceFound'/'serviceLost') 浏览回调,startSearchingMDNS/
 *   stopSearchingMDNS 控制启停 —— 同一实例可反复启停;
 * - serviceFound 的 LocalServiceInfo 只保证 serviceName(其余字段
 *   可选),IP/端口/TXT 必须经 resolveLocalService(context,
 *   {serviceType, serviceName}) 补全(2204006 = 解析超时);
 * - TXT 是 serviceAttribute: Array<{key, value: Array<number>}>(字节),
 *   相机侧 guid/vid/pid/ver/apps 全 ASCII,逐字节透传解码;
 * - serviceType 按本 d.ts 惯例**不带尾点**('_ptp._tcp');iOS
 *   NetServiceBrowser 与 Android NsdManager 均带尾点,三端各按平台
 *   文档,待真机核对(记录见 TODO.md 实现注意事项)。
 *
 * 契约要点(与 iOS NsdPlugin.swift 同构):
 * - 纯 DNS-SD 解析,绝不向相机发 TCP 连接(单连接服务器,探测性
 *   连接会被保持并呛住后续连接);
 * - start 幂等:先停再启并清空旧记账;
 * - Dart 尚未挂监听的窗口期事件丢弃即可(found 随 mDNS 周期重播)。
 */
import mdns from '@ohos.net.mdns';
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  AbilityAware,
  AbilityPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  EventChannel,
  EventSink,
  Log,
} from '@ohos/flutter_ohos';

const TAG = 'NsdPlugin';

/// 浏览的服务类型(PTP/IP,SRV 端口 15740;无尾点,待真机核对)。
const SERVICE_TYPE = '_ptp._tcp';

/// Dart 契约的兜底端口(DiscoveredIpCamera.fromMap 的默认值同源)。
const DEFAULT_PORT = 15740;

/** `nikonpill/nsd` + `nikonpill/nsd/events` 通道实现。 */
export class NsdPlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private context: common.Context | null = null;
  private ability: UIAbility | null = null;
  private discovery: mdns.DiscoveryService | null = null;
  private searching = false;
  /// 已知服务实例名(serviceFound 去重;lost 后移除,resolve 失败回滚)。
  private known: Map<string, boolean> = new Map();

  getUniqueClassName(): string {
    return 'NsdPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/nsd');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    this.events = new EventChannel(binding.getBinaryMessenger(), 'nikonpill/nsd/events');
    this.events.setStreamHandler({
      onListen: (args: ESObject, events: EventSink): void => {
        this.sink = events;
      },
      onCancel: (): void => {
        this.sink = null;
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.events = null;
    this.sink = null;
    this.teardownDiscovery();
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
  }

  onDetachedFromAbility(): void {
    this.ability = null;
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'start':
        this.start(result);
        break;
      case 'stop':
        this.stop(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// Context 取用:applicationContext 为主(mdns 不需要 UI 上下文),
  /// 兜底 ability context;app context 若被运行时拒绝,后备即生效。
  private ctx(): common.Context | null {
    return this.context ?? this.ability?.context ?? null;
  }

  /// 开始浏览(幂等:已激活先停,清空旧记账再启)。
  private start(result: MethodResult): void {
    const ctx = this.ctx();
    if (ctx === null) {
      result.error('nsd_error', 'context 未就绪', null);
      return;
    }
    try {
      if (this.discovery === null) {
        const svc = mdns.createDiscoveryService(ctx, SERVICE_TYPE);
        svc.on('discoveryStart', (info: mdns.DiscoveryEventInfo): void => {
          if (info.errorCode !== undefined) {
            Log.w(TAG, `discoveryStart errorCode=${info.errorCode}`);
            this.searching = false;
          }
        });
        svc.on('discoveryStop', (info: mdns.DiscoveryEventInfo): void => {
          if (info.errorCode !== undefined) {
            Log.w(TAG, `discoveryStop errorCode=${info.errorCode}`);
          }
        });
        svc.on('serviceFound', (info: mdns.LocalServiceInfo): void => {
          this.handleFound(ctx, info);
        });
        svc.on('serviceLost', (info: mdns.LocalServiceInfo): void => {
          this.handleLost(info);
        });
        this.discovery = svc;
      } else if (this.searching) {
        this.discovery.stopSearchingMDNS();
      }
      this.known.clear();
      this.searching = true;
      this.discovery.startSearchingMDNS();
      result.success(null);
    } catch (e) {
      this.searching = false;
      result.error('nsd_error', `start: ${e}`, null);
    }
  }

  /// 停止浏览(幂等)。
  private stop(result: MethodResult): void {
    this.pauseSearching();
    this.known.clear();
    result.success(null);
  }

  private pauseSearching(): void {
    if (this.discovery !== null && this.searching) {
      this.searching = false;
      try {
        this.discovery.stopSearchingMDNS();
      } catch (e) {
        Log.w(TAG, `stopSearchingMDNS: ${e}`);
      }
    } else {
      this.searching = false;
    }
  }

  /// 彻底拆解(引擎分离):停搜索 + 摘监听。off 不带 callback =
  /// 摘除该事件全部监听(d.ts 可选参数语义)。
  private teardownDiscovery(): void {
    this.pauseSearching();
    const svc = this.discovery;
    this.discovery = null;
    this.known.clear();
    if (svc === null) {
      return;
    }
    try {
      svc.off('discoveryStart');
      svc.off('discoveryStop');
      svc.off('serviceFound');
      svc.off('serviceLost');
    } catch (e) {
      Log.w(TAG, `off: ${e}`);
    }
  }

  /// serviceFound:去重 → resolveLocalService 补全 IP/端口/TXT → 上报。
  /// resolve 失败(服务消失/超时 2204006)回滚记账,等 mDNS 重播再试。
  private handleFound(ctx: common.Context, info: mdns.LocalServiceInfo): void {
    const name = info.serviceName;
    if (name.length === 0 || this.known.has(name)) {
      return;
    }
    this.known.set(name, true);
    const request: mdns.LocalServiceInfo = {
      serviceType: SERVICE_TYPE,
      serviceName: name,
    };
    mdns.resolveLocalService(ctx, request)
      .then((resolved: mdns.LocalServiceInfo): void => {
        if (!this.known.has(name)) {
          return; // 等待期间已 lost/停止:丢弃
        }
        this.emitFound(resolved);
      })
      .catch((e: Object): void => {
        Log.w(TAG, `resolveLocalService(${name}): ${e}`);
        this.known.delete(name);
      });
  }

  /// serviceLost:仅在已知(上报过/在解析)时报丢失,与 iOS 同构。
  private handleLost(info: mdns.LocalServiceInfo): void {
    const name = info.serviceName;
    if (this.known.delete(name)) {
      this.emit({ 'event': 'lost', 'name': name } as Record<string, Object>);
    }
  }

  private emitFound(resolved: mdns.LocalServiceInfo): void {
    const txt: Record<string, string> = {};
    const attrs = resolved.serviceAttribute ?? [];
    for (const attr of attrs) {
      txt[attr.key] = decodeTxtValue(attr.value);
    }
    const host = resolved.host?.address ?? '';
    this.emit({
      'event': 'found',
      'name': resolved.serviceName,
      'host': host,
      'port': resolved.port ?? DEFAULT_PORT,
      'txt': txt,
    } as Record<string, Object>);
    if (host.length === 0) {
      // 解析成功但没拿到 IP:事件已发(host 空,Dart 侧过滤无 host 项),
      // 留日志便于真机排查。
      Log.w(TAG, `resolveLocalService(${resolved.serviceName}) 未返回 host`);
    }
  }

  private emit(payload: Record<string, Object>): void {
    if (this.sink !== null) {
      this.sink.success(payload);
    }
  }
}

/// TXT value 字节 → 字符串:相机侧键值(guid/vid/pid/ver/apps)全
/// ASCII,逐字节透传(Latin-1)即可;引入 TextDecoder 无增益。
function decodeTxtValue(bytes: Array<number>): string {
  let out = '';
  for (const b of bytes) {
    out += String.fromCharCode(b & 0xff);
  }
  return out;
}
