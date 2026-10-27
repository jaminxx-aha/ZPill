/**
 * ZPill 程序化加入 Wi-Fi(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/network_monitor.dart 的 WifiJoiner
 * (通道 `zpill/network`,方法 join/release)—— BLE→WiFi 交接
 * (SnapBridge 同款):0x2004 凭据 → 0x2005 断 BLE → join 相机热点 →
 * PTP/IP。Android 同名插件(WifiNetworkSpecifier)已先行,iOS 待
 * Network Extensions entitlement。
 *
 * ohos API 要点(@ohos.wifiManager,DevEco apiVersion 24 面 / 真机 26):
 * - 三方正路 = **候选配置族**(connectToNetwork 要 MANAGE_WIFI_CONNECTION
 *   system_basic,三方拿不到):addCandidateConfig + connectToCandidateConfig
 *   都只要 ohos.permission.SET_WIFI_INFO(normal,声明即得),须应用前台
 *   —— 配对/连接流程天然在前台;
 * - candidate 配置只连本 app 加的;重复 join 先 removeCandidateConfig
 *   清旧(幂等,清不掉忽略);
 * - 静默 connectToCandidateConfig 无回执(void):join 定局 = 轮询
 *   isConnected()+getLinkedInfoSync().ssid 命中(1s × 30s 看门狗);
 *   ~6s 未上链升级 connectToCandidateConfigWithUserAction(API 20+,
 *   弹系统确认;2501005 未响应/2501006 拒绝如实收场),轮询并行继续;
 * - enableWifi 要 MANAGE_WIFI_CONNECTION(拿不到):Wi-Fi 总闸关着只能
 *   isWifiActive 先查如实回错,由 UI 引导去开;
 * - 网关 = getIpInfo().gateway —— int 小端(同 Android DhcpInfo 约定:
 *   192.168.1.1 存 0x0101A8C0),0/负 = 无租约;相机 AP 的网关即相机
 *   本机 IP,Dart 侧候选序消费(缺省回落 192.168.1.1)。
 *
 * 0x2004 安全字节(Android NetworkPlugin 同映射):0x01 开放 / 0x02
 * WPA2 / 0x03 WPA3 / 0x04 WPA2+WPA3 / 0x00 未定义;密码空一律开放,
 * 0x03 → SAE(WPA3),其余有密码 → PSK(兼容侧)。
 */
import wifi from '@ohos.wifiManager';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  Log,
} from '@ohos/flutter_ohos';

const TAG = 'NetworkPlugin';
const CHANNEL = 'zpill/network';

/** 轮询节奏与总限(相机热点上线 + 关联 + DHCP 需数秒,30s 与 Android 看门狗同限)。 */
const POLL_MS = 1000;
const JOIN_TIMEOUT_MS = 30000;
/** 静默连未上链多久后升级系统确认弹窗。 */
const ESCALATE_AFTER_MS = 6000;

/** `zpill/network` 通道实现。 */
export class NetworkPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private pendingJoin: MethodResult | null = null;
  private ownedNetworkId: number | null = null;
  private pollTimerId: number = -1;
  private escalateAt = 0;
  private escalated = false;

  getUniqueClassName(): string {
    return 'NetworkPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.release();
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    Log.i(TAG, `method=${call.method}`);
    switch (call.method) {
      case 'join': {
        // Dart Map 经 codec 到 ohos 是 ES Map:走 call.argument
        // (BlePlugin 同款)。
        const ssid = call.argument('ssid') as string ?? '';
        const password = call.argument('password') as string ?? '';
        const security = call.argument('security') as number ?? 0;
        this.join(ssid, password, security, result);
        break;
      }
      case 'release':
        this.release();
        result.success(null);
        break;
      case 'scanAps':
        this.scanAps(result);
        break;
      default:
        result.notImplemented();
    }
  }

  /** 扫描周边 AP(0x2004 解密未中的 B 路:相机热点 SSID 靠扫描锁定)。
   * 触发一轮扫描,2.5s 后取缓存列表;security 归一到 0x2004 字节约定
   * (0x01 开放/0x02 WPA2/0x03 WPA3),Dart 侧按启发式/相机名过滤。 */
  private scanAps(result: MethodResult): void {
    try {
      wifi.scan();
    } catch (e) {
      Log.w(TAG, `scan: ${e}`);
    }
    setTimeout((): void => {
      try {
        const list = wifi.getScanInfoList();
        const out: Record<string, Object>[] = [];
        for (const ap of list) {
          const ssid = (ap.ssid ?? '') as string;
          if (ssid === '') {
            continue;
          }
          out.push({
            'ssid': ssid,
            'security': this.normSec(ap.securityType),
            'rssi': ap.rssi,
          });
        }
        result.success(out);
      } catch (e) {
        Log.w(TAG, `getScanInfoList: ${JSON.stringify(e)}`);
        result.success([]);
      }
    }, 2500);
  }

  /** ohos WifiSecurityType 枚举 → 0x2004 字节约定(join 消费)。 */
  private normSec(t: wifi.WifiSecurityType): number {
    switch (t) {
      case wifi.WifiSecurityType.WIFI_SEC_TYPE_OPEN:
        return 0x01;
      case wifi.WifiSecurityType.WIFI_SEC_TYPE_SAE:
        return 0x03;
      case wifi.WifiSecurityType.WIFI_SEC_TYPE_WEP:
        return 0x02;
      default:
        return 0x02; // PSK 及未知 → WPA2 侧
    }
  }

  private join(ssid: string, password: string, security: number,
    result: MethodResult): void {
    if (ssid === '') {
      result.success({ 'ok': false, 'reason': 'empty ssid' });
      return;
    }
    try {
      if (!wifi.isWifiActive()) {
        // 总闸开关在系统手里(enableWifi 要 system_basic 权限)。
        result.success({ 'ok': false, 'reason': 'wifi off' });
        return;
      }
    } catch (e) {
      Log.w(TAG, `isWifiActive: ${e}`);
    }
    // 重复 join:在途结果以 released 收场,旧候选配置清掉,新的顶上。
    if (this.pendingJoin !== null) {
      this.settleJoin({ 'ok': false, 'reason': 'released' });
    }
    this.dropOwnedConfig();
    this.pendingJoin = result;
    try {
      const cfg: wifi.WifiDeviceConfig = {
        ssid: ssid,
        preSharedKey: password,
        securityType: this.secType(security, password),
      };
      wifi.addCandidateConfig(cfg).then((networkId: number): void => {
        if (this.pendingJoin === null) {
          // 在途已被 release/repeat 清场:配置照删,不留垃圾。
          this.forgetConfig(networkId);
          return;
        }
        if (networkId < 0) {
          this.settleJoin({ 'ok': false, 'reason': 'config rejected' });
          return;
        }
        this.ownedNetworkId = networkId;
        this.escalated = false;
        this.escalateAt = Date.now() + ESCALATE_AFTER_MS;
        try {
          wifi.connectToCandidateConfig(networkId);
        } catch (e) {
          Log.w(TAG, `connectToCandidateConfig: ${e}`);
        }
        const deadline = Date.now() + JOIN_TIMEOUT_MS;
        this.pollJoin(ssid, networkId, deadline);
      }).catch((e: Object): void => {
        Log.w(TAG, `addCandidateConfig: ${JSON.stringify(e)}`);
        this.settleJoin({ 'ok': false, 'reason': `${JSON.stringify(e)}` });
      });
    } catch (e) {
      Log.e(TAG, `join EXC: ${JSON.stringify(e)}`);
      this.settleJoin({ 'ok': false, 'reason': `${JSON.stringify(e)}` });
    }
  }

  /** 0x2004 安全字节 → ohos 枚举(映射见类注)。 */
  private secType(security: number, password: string): wifi.WifiSecurityType {
    if (password === '') {
      return wifi.WifiSecurityType.WIFI_SEC_TYPE_OPEN;
    }
    if (security === 0x03) {
      return wifi.WifiSecurityType.WIFI_SEC_TYPE_SAE; // WPA3
    }
    return wifi.WifiSecurityType.WIFI_SEC_TYPE_PSK; // WPA2/兼容侧
  }

  /** join 定局轮询:上链(SSID 命中)即收场,超时如实回。 */
  private pollJoin(ssid: string, networkId: number, deadline: number): void {
    if (this.pendingJoin === null) {
      return; // 已被 release/repeat 清场
    }
    try {
      if (wifi.isConnected()) {
        const info = wifi.getLinkedInfoSync();
        const linked = (info.ssid ?? '') as string;
        // SSID 精确命中优先;个别栈回带引号/杂缀,包含兜底。
        if (linked === ssid || linked.includes(ssid)) {
          const payload: Record<string, Object> = { 'ok': true };
          const gw = this.gatewayDotted();
          if (gw !== null) {
            payload['gateway'] = gw;
          }
          this.settleJoin(payload);
          return;
        }
      }
    } catch (e) {
      Log.w(TAG, `poll: ${e}`);
    }
    // 静默连无回执:宽限一拍未上链升级系统确认弹窗(用户拒/未响应
    // 即刻收场,其余继续轮询 —— 弹窗与上链并行)。
    if (!this.escalated && Date.now() >= this.escalateAt) {
      this.escalated = true;
      wifi.connectToCandidateConfigWithUserAction(networkId)
        .catch((e: BusinessError): void => {
          Log.w(TAG, `WithUserAction: ${e.code} ${e.message}`);
          if (e.code === 2501006) {
            this.settleJoin({ 'ok': false, 'reason': 'user refused' });
          } else if (e.code === 2501005) {
            this.settleJoin({ 'ok': false, 'reason': 'no response' });
          }
        });
    }
    if (Date.now() >= deadline) {
      this.settleJoin({ 'ok': false, 'reason': 'timeout' });
      return;
    }
    this.pollTimerId = setTimeout((): void => {
      this.pollTimerId = -1;
      this.pollJoin(ssid, networkId, deadline);
    }, POLL_MS);
  }

  /** DHCP 网关点分化。ohos IpInfo.gateway 是 int **大端**打包(网络
   * 字节序:192.168.1.1 = 0xC0A80101,真机 2026-10-23 实证 —— 与
   * Android DhcpInfo 的小端相反);0/负 = 无租约 → null。 */
  private gatewayDotted(): string | null {
    try {
      const g = wifi.getIpInfo().gateway;
      if (g === undefined || g === null || g <= 0) {
        return null;
      }
      return `${(g >>> 24) & 0xff}.${(g >>> 16) & 0xff}.` +
        `${(g >>> 8) & 0xff}.${g & 0xff}`;
    } catch (e) {
      Log.w(TAG, `getIpInfo: ${e}`);
      return null;
    }
  }

  /** join 结果只回一次(照 BlePlugin pending-Result 模式)。 */
  private settleJoin(payload: Record<string, Object>): void {
    if (this.pollTimerId !== -1) {
      clearTimeout(this.pollTimerId);
      this.pollTimerId = -1;
    }
    const pending = this.pendingJoin;
    this.pendingJoin = null;
    pending?.success(payload);
  }

  /** 清本 app 的候选配置(释放路;网络本身不断 —— disconnect 要
   * system_basic 权限,系统自会按候选淘汰)。 */
  private release(): void {
    if (this.pendingJoin !== null) {
      this.settleJoin({ 'ok': false, 'reason': 'released' });
    }
    this.dropOwnedConfig();
  }

  private dropOwnedConfig(): void {
    if (this.ownedNetworkId !== null) {
      this.forgetConfig(this.ownedNetworkId);
      this.ownedNetworkId = null;
    }
  }

  private forgetConfig(networkId: number): void {
    try {
      wifi.removeCandidateConfig(networkId)
        .catch((e: BusinessError): void => {
          Log.w(TAG, `removeCandidateConfig: ${e.code} ${e.message}`);
        });
    } catch (e) {
      Log.w(TAG, `removeCandidateConfig EXC: ${e}`);
    }
  }
}
