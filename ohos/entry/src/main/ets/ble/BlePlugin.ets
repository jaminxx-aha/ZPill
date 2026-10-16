/**
 * NikonPill BLE 裸桥(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/ble_scanner.dart(BleHost):
 * MethodChannel `nikonpill/ble` + EventChannel `nikonpill/ble/events`。
 * 协议逻辑(配对握手/GEO/TIME 载荷)全在 Dart(lib/core/ble/),本桥
 * 只做扫描/连接/GATT 搬运,零 Nikon 方言知识 —— 唯一例外:bondDevice
 * (程序化经典蓝牙绑定;鸿蒙公开 API 可为,iOS 无此路 —— 首配注册用)。
 *
 * 事件载荷(Map,与 iOS BlePlugin 同形):state / discovered /
 * connected(附全特征表与 MTU)/ disconnected / notify / error / bond。
 *
 * ohos API 要点(@kit.ConnectivityKit,API 15+):
 * - 扫描 = ble.createBleScanner()(旧 ble.on 单扫 API 已废弃),
 *   ScanReport{reportType, scanResult[]} 只吃 ON_FOUND(1);
 * - 厂商数据在 sr.manufacturerDataMap,键 = 公司 ID(0x0399),值
 *   **不含**两字节 ID 前缀(与 iOS 不同,对外补齐成同形);
 * - GATT = ble.createGattClientDevice(deviceId),连接态 2=连/0=断;
 *   特征订阅 = setCharacteristicChangeNotification,indicate 特征须再
 *   手写 CCCD 描述符 0x0200(notify 特征 CCN 即生效);
 * - 绑定 = connection.startBluetoothDiscovery + pairDevice +
 *   bondStateChange(经典蓝牙;匹配按名字/序列号,防误配兄弟机身)。
 */
import { ble, connection, bluetooth } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import abilityAccessCtrl, { PermissionRequestResult } from '@ohos.abilityAccessCtrl';
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
import { NativeLog } from '../log/NativeLog';

const TAG = 'BlePlugin';
const SVC = '0000DE00-3DD4-4255-8D62-6DC7B9BD5561';
const NIKON_COMPANY_ID = 0x0399;
const CCCD_UUID = '00002902-0000-1000-8000-00805F9B34FB';

/** 一台扫描命中的设备(去重键 = deviceId)。 */
interface ScanHit {
  deviceId: string;
  name: string;
  rssi: number;
  mfg: Uint8Array; // 含 [0x99,0x03] 前缀(对外与 iOS 同形);无则空
}

/** 单笔在途写(排队串行;回调解锁后取下一笔)。 */
class PendingWrite {
  uuid: string = '';
  data: Uint8Array = new Uint8Array(0);
  result: MethodResult | null = null;
}

/** `nikonpill/ble` + `nikonpill/ble/events` 通道实现。 */
export class BlePlugin implements FlutterPlugin, AbilityAware {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private ability: UIAbility | null = null;

  // 扫描
  private scanner: ble.BleScanner | null = null;
  private scanHits: ScanHit[] = [];
  private scanFilterDeviceId: number | null = null;
  private scanResult: MethodResult | null = null;
  private scanTimerId: number = -1;

  // 连接 / GATT
  private gattClient: ble.GattClientDevice | null = null;
  private deviceId: string = '';
  private charMap: Map<string, ble.BLECharacteristic> = new Map();
  private propsMap: Map<string, string> = new Map();
  private lastMtu: number = 20;
  private pendingConnect: MethodResult | null = null;
  private writeBusy = false;
  private writeQueue: PendingWrite[] = [];
  // 服务发现:链路未稳时 getServices 回空表(D5600/Zf 实证),须等 MTU
  // 协商完成再发现 + 空表重试(HarmoNiLink 同款节奏:3 次 × 2s)
  private discoveryRetries = 0;
  private discoveryInFlight = false;
  private discoveryDone = false;
  private mtuTimerId = -1;

  getUniqueClassName(): string {
    return 'BlePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel =
      new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/ble');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    this.events =
      new EventChannel(binding.getBinaryMessenger(), 'nikonpill/ble/events');
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
    Log.i(TAG, `method=${call.method} args=${JSON.stringify(call.args)}`);
    switch (call.method) {
      case 'isAvailable':
        this.ensureBluetoothPermission(() => {
          let on = false;
          try {
            on = (bluetooth.getState() as number) === 2; // STATE_ON
          } catch (e) {
            Log.w(TAG, `getState: ${e}`);
          }
          result.success(on);
        });
        break;
      case 'scan':
        this.ensureBluetoothPermission(() => {
          this.startScan(this.argNumber(call, 'seconds') ?? 10, null, result);
        });
        break;
      case 'scanForDeviceId':
        this.ensureBluetoothPermission(() => {
          this.startScan(this.argNumber(call, 'seconds') ?? 10,
            this.argNumber(call, 'deviceId'), result);
        });
        break;
      case 'stopScan':
        this.stopScanNative();
        result.success(null);
        break;
      case 'connectPaired':
        this.ensureBluetoothPermission(() => {
          this.connectPaired(call.args as string, result);
        });
        break;
      case 'setNotify':
        this.setNotify(call.args as string, result);
        break;
      case 'read':
        this.read(call.args as string, result);
        break;
      case 'write': {
        // Dart Map 经 codec 到 ohos 是 ES Map:方括号访问取不到,
        // 必须走 call.argument()(内部 Map.get,UsbHostPlugin 同款)
        const uuid = call.argument('uuid') as string ?? '';
        const data = call.argument('data') as Uint8Array ?? new Uint8Array(0);
        this.write(uuid, data, result);
        break;
      }
      case 'disconnect':
        this.disconnectNative();
        result.success(null);
        break;
      case 'bondDevice': {
        this.ensureBluetoothPermission(() => {
          this.bondDevice(call.argument('deviceId') as string ?? '',
            call.argument('name') as string ?? '',
            call.argument('serial') as string ?? '', result);
        });
        break;
      }
      default:
        result.notImplemented();
    }
  }

  private argNumber(call: MethodCall, key: string): number | null {
    const v = call.argument(key) as number;
    return typeof v === 'number' ? v : null;
  }

  /** ACCESS_BLUETOOTH 为 user_grant:首次扫描/连接/绑定时向系统要一次。 */
  private ensureBluetoothPermission(onReady: () => void): void {
    const ctx = this.ability?.context ?? null;
    if (ctx === null) {
      onReady();
      return;
    }
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(ctx, ['ohos.permission.ACCESS_BLUETOOTH'])
      .then((res: PermissionRequestResult): void => {
        for (const status of res.authResults) {
          if (status !== 0) {
            this.emit({
              'type': 'error', 'code': 'permissionDenied',
              'message': '蓝牙权限未授权', 'uuid': '',
            });
            return;
          }
        }
        onReady();
      })
      .catch((e: Object): void => {
        Log.w(TAG, `requestPermissionsFromUser: ${e}`);
        onReady();
      });
  }

  // ------------------------------------------------------------------
  // 扫描
  // ------------------------------------------------------------------

  private startScan(seconds: number, filterDeviceId: number | null,
    result: MethodResult): void {
    if (this.scanResult !== null) {
      result.error('busy', '已有扫描在进行', null);
      return;
    }
    if (this.scanner !== null) {
      this.stopScanNative(); // 上一次的定时器/监听未清(防御)
    }
    this.scanFilterDeviceId = filterDeviceId;
    this.scanHits = [];
    this.scanResult = result;
    try {
      this.scanner = ble.createBleScanner();
      this.scanner.on('BLEDeviceFind', (report: Object): void => {
        this.onScanReport(report);
      });
      const opts: ble.ScanOptions = {
        interval: 100,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      };
      this.scanner.startScan(null, opts);
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `startScan: ${e.code} ${e.message}`);
      this.scanResult = null;
      this.scanner = null;
      result.error('scanFailed', `${e.message}`, null);
      return;
    }
    this.scanTimerId = setTimeout((): void => {
      this.finishScan();
    }, seconds * 1000);
  }

  private onScanReport(report: Object): void {
    const r = report as Record<string, Object>;
    const reportType = (r['reportType'] as number) ?? -1;
    if (reportType !== -1 && reportType !== 1) {
      return; // 只吃 ON_FOUND
    }
    const inner = r['scanResult'];
    const arr = inner !== undefined && inner !== null
      ? inner as Object[]
      : [report];
    for (let i = 0; i < arr.length; i++) {
      const sr = arr[i] as Record<string, Object>;
      const id = (sr['deviceId'] as string) ?? '';
      if (id === '') {
        continue;
      }
      const name = (sr['deviceName'] as string) ?? '';
      const rssi = (sr['rssi'] as number) ?? 0;
      const mfg = this.parseNikonMfg(sr); // 含 [0x99,0x03] 前缀;无则空
      if (this.scanFilterDeviceId !== null) {
        // 重连过滤:厂商数据 = 0x0399 + deviceId 小端 4B
        if (mfg.length < 6) {
          continue;
        }
        const dev = mfg[2] + mfg[3] * 0x100 + mfg[4] * 0x10000
          + mfg[5] * 0x1000000;
        if (dev !== this.scanFilterDeviceId) {
          continue;
        }
      } else {
        // 配对扫描:尼康机身(名 Z 开头系 / LSS 服务 / 尼康厂商数据)
        const svcs = (sr['serviceUuids'] as string[] ?? []) as string[];
        const svcHit = svcs.some((u: string): boolean =>
          u.toUpperCase().includes('DE00'));
        const nameHit = name.startsWith('Z ') || name.includes('Z_f');
        if (!svcHit && mfg.length === 0 && !nameHit) {
          continue;
        }
      }
      const idx = this.scanHits.findIndex((h: ScanHit): boolean =>
        h.deviceId === id);
      const hit: ScanHit = { deviceId: id, name: name, rssi: rssi, mfg: mfg };
      if (idx >= 0) {
        this.scanHits[idx] = hit;
      } else {
        this.scanHits.push(hit);
      }
      this.emit({
        'type': 'discovered', 'name': name, 'uuid': id,
        'rssi': rssi, 'mfg': mfg,
      });
    }
  }

  /** 取尼康厂商数据并补齐 [0x99,0x03] 前缀(ohos map 值不含 ID 前缀)。 */
  private parseNikonMfg(sr: Record<string, Object>): Uint8Array {
    const mmap = sr['manufacturerDataMap'] as Map<number, Uint8Array> | undefined;
    if (mmap === undefined || mmap === null) {
      return new Uint8Array(0);
    }
    const v = mmap.get(NIKON_COMPANY_ID);
    if (v === undefined || v === null || v.length === 0) {
      return new Uint8Array(0);
    }
    const out = new Uint8Array(v.length + 2);
    out[0] = 0x99;
    out[1] = 0x03;
    for (let i = 0; i < v.length; i++) {
      out[i + 2] = v[i];
    }
    return out;
  }

  private stopScanNative(): void {
    if (this.scanTimerId !== -1) {
      clearTimeout(this.scanTimerId);
      this.scanTimerId = -1;
    }
    if (this.scanner !== null) {
      try {
        this.scanner.off('BLEDeviceFind');
        this.scanner.stopScan();
      } catch (e) {
        Log.w(TAG, `stopScan: ${e}`);
      }
      this.scanner = null;
    }
  }

  private finishScan(): void {
    this.stopScanNative();
    const result = this.scanResult;
    this.scanResult = null;
    if (result === null) {
      return;
    }
    const list: Record<string, Object>[] = [];
    for (const h of this.scanHits) {
      list.push({
        'name': h.name, 'uuid': h.deviceId, 'rssi': h.rssi,
        'mfg': h.mfg,
      });
    }
    result.success(list);
  }

  // ------------------------------------------------------------------
  // 连接 / GATT
  // ------------------------------------------------------------------

  private connectPaired(uuid: string, result: MethodResult): void {
    if (uuid === '') {
      result.error('badArgs', 'connectPaired 须传设备标识', null);
      return;
    }
    if (this.gattClient !== null) {
      // 单客户端纪律:旧句柄不 close 会把迟到回调混进新连接
      this.teardownGatt();
    }
    this.deviceId = uuid;
    this.charMap.clear();
    this.propsMap.clear();
    this.discoveryRetries = 0;
    this.discoveryDone = false;
    this.pendingConnect = result;
    try {
      this.gattClient = ble.createGattClientDevice(uuid);
      this.gattClient.on('BLEConnectionStateChange',
        (d: ble.BLEConnectionChangeState): void => {
          if (d.state === 2) {
            try {
              this.gattClient?.setBLEMtuSize(517);
            } catch (e) {
              Log.w(TAG, `setBLEMtuSize: ${e}`);
            }
            // MTU 协商兜底:5s 没等到 BLEMtuChange 也强行发现
            if (this.mtuTimerId === -1) {
              this.mtuTimerId = setTimeout((): void => {
                this.mtuTimerId = -1;
                this.discoverServices();
              }, 5000);
            }
          } else if (d.state === 0) {
            NativeLog.w('ble', `BLE 断连:${this.deviceId}`);
            const pending = this.pendingConnect;
            this.pendingConnect = null;
            if (pending !== null) {
              pending.error('connectFailed', '连接在服务发现前断开', null);
            }
            this.emit({ 'type': 'disconnected', 'uuid': this.deviceId });
          }
        });
      this.gattClient.on('BLEMtuChange', (mtu: number): void => {
        this.lastMtu = mtu;
        if (this.mtuTimerId !== -1) {
          clearTimeout(this.mtuTimerId);
          this.mtuTimerId = -1;
        }
        this.discoverServices();
      });
      this.gattClient.on('BLECharacteristicChange',
        (d: ble.BLECharacteristic): void => {
          const u = (d.characteristicUuid as string ?? '').toLowerCase();
          const v = d.characteristicValue;
          const bytes = v instanceof Uint8Array ? v : new Uint8Array(v);
          this.emit({ 'type': 'notify', 'uuid': u, 'data': bytes });
        });
      this.gattClient.connect();
    } catch (err) {
      const e = err as BusinessError;
      Log.e(TAG, `connect: ${e.code} ${e.message}`);
      NativeLog.w('ble', `connect 失败:${e.code} ${e.message}`);
      this.pendingConnect = null;
      this.gattClient = null;
      result.error('connectFailed', `${e.message}`, null);
    }
  }

  private discoverServices(): void {
    const client = this.gattClient;
    if (client === null) {
      return; // 迟到的看门狗回调
    }
    if (this.discoveryDone || this.discoveryInFlight) {
      return;
    }
    this.discoveryInFlight = true;
    const c = client as Object as Record<string, Function>;
    try {
      c['getServices']((err: BusinessError, services: Object): void => {
        this.discoveryInFlight = false;
        if (this.gattClient !== client) {
          return; // 连接已换
        }
        if (err) {
          Log.e(TAG, `getServices: ${err.code} ${err.message}`);
          const pending = this.pendingConnect;
          this.pendingConnect = null;
          pending?.error('discoveryFailed', `${err.message}`, null);
          return;
        }
        const arr = Array.isArray(services) ? services as Object[]
          : ((services as Record<string, Object>)['services'] as Object[]) ?? [];
        const chars: Record<string, string> = {};
        for (let i = 0; i < arr.length; i++) {
          const svc = arr[i] as Record<string, Object>;
          const list = svc['characteristics'] as Object[] ?? [];
          for (let j = 0; j < list.length; j++) {
            const ch = list[j] as Record<string, Object>;
            const u = (ch['characteristicUuid'] as string ?? '').toLowerCase();
            this.charMap.set(u, ch as Object as ble.BLECharacteristic);
            const props = ch['properties'] as Record<string, boolean> ?? {};
            const flags: string[] = [];
            if (props['read'] === true) {
              flags.push('read');
            }
            if (props['write'] === true) {
              flags.push('write');
            }
            if (props['writeNoReply'] === true) {
              flags.push('writeWithoutResponse');
            }
            if (props['notify'] === true) {
              flags.push('notify');
            }
            if (props['indicate'] === true) {
              flags.push('indicate');
            }
            this.propsMap.set(u, flags.join('|'));
            chars[u] = flags.join('|');
          }
        }
        // 空表/缺 PAIR = 链路未稳(D5600/Zf 实证)→ 重试后再判
        if (!this.charMap.has('00002000-3dd4-4255-8d62-6dc7b9bd5561')) {
          if (this.discoveryRetries < 2) {
            this.discoveryRetries++;
            Log.w(TAG, `getServices 空表/缺 PAIR — 重试(${this.discoveryRetries}/2)`);
            setTimeout((): void => {
              this.discoverServices();
            }, 2000);
            return;
          }
          Log.e(TAG, 'getServices: LSS 服务未发现');
          const pending = this.pendingConnect;
          this.pendingConnect = null;
          pending?.error('discoveryFailed', '未发现 LSS 服务(链路未稳或非尼康机身)', null);
          return;
        }
        this.discoveryDone = true;
        this.emit({
          'type': 'connected', 'uuid': this.deviceId,
          'characteristics': chars, 'mtu': this.lastMtu,
        });
        const pending = this.pendingConnect;
        this.pendingConnect = null;
        pending?.success(null);
      });
    } catch (e) {
      this.discoveryInFlight = false;
      Log.e(TAG, `getServices EXC: ${JSON.stringify(e)}`);
      const pending = this.pendingConnect;
      this.pendingConnect = null;
      pending?.error('discoveryFailed', `${JSON.stringify(e)}`, null);
    }
  }

  private findChar(uuid: string): ble.BLECharacteristic | null {
    const ch = this.charMap.get(uuid.toLowerCase());
    return ch === undefined ? null : ch;
  }

  private setNotify(uuid: string, result: MethodResult): void {
    const client = this.gattClient;
    const ch = this.findChar(uuid);
    if (client === null || ch === null) {
      result.error('notFound', `特征不存在:${uuid}`, null);
      return;
    }
    const indicate = (this.propsMap.get(uuid.toLowerCase()) ?? '')
      .includes('indicate');
    const c = client as Object as Record<string, Function>;
    try {
      c['setCharacteristicChangeNotification'](ch, true,
        (err: BusinessError): void => {
          if (err) {
            Log.w(TAG, `CCN ${uuid}: ${err.code} ${err.message}`);
          }
          if (!indicate) {
            // notify 特征:CCN 即生效(栈内写 CCCD 0x0001)
            result.success(null);
            return;
          }
          // indicate 特征:必须手写 CCCD 0x0200
          const buf = new ArrayBuffer(2);
          const v = new Uint8Array(buf);
          v[0] = 0x02;
          v[1] = 0x00;
          const desc: Record<string, Object> = {
            'serviceUuid': SVC,
            'characteristicUuid': uuid,
            'descriptorUuid': CCCD_UUID,
            'descriptorValue': buf,
          };
          try {
            c['writeDescriptorValue'](desc, (err2: BusinessError): void => {
              if (err2) {
                Log.w(TAG, `CCCD ${uuid}: ${err2.code} ${err2.message}`);
              }
              result.success(null);
            });
          } catch (e) {
            Log.e(TAG, `writeDescriptor EXC: ${JSON.stringify(e)}`);
            result.error('notifyFailed', `${JSON.stringify(e)}`, null);
          }
        });
    } catch (e) {
      Log.e(TAG, `setNotify EXC: ${JSON.stringify(e)}`);
      result.error('notifyFailed', `${JSON.stringify(e)}`, null);
    }
  }

  private read(uuid: string, result: MethodResult): void {
    const client = this.gattClient;
    const ch = this.findChar(uuid);
    if (client === null || ch === null) {
      result.error('notFound', `特征不存在:${uuid}`, null);
      return;
    }
    const c = client as Object as Record<string, Function>;
    try {
      c['readCharacteristicValue'](ch, (err: BusinessError,
        out: ble.BLECharacteristic): void => {
        if (err) {
          result.error('readFailed', `${err.message}`, null);
          return;
        }
        const v = out.characteristicValue;
        result.success(v instanceof Uint8Array ? v : new Uint8Array(v));
      });
    } catch (e) {
      result.error('readFailed', `${JSON.stringify(e)}`, null);
    }
  }

  private write(uuid: string, data: Uint8Array, result: MethodResult): void {
    const pending = new PendingWrite();
    pending.uuid = uuid;
    pending.data = data;
    pending.result = result;
    this.writeQueue.push(pending);
    if (!this.writeBusy) {
      this.flushWrites();
    }
  }

  private flushWrites(): void {
    const head = this.writeQueue.shift();
    if (head === undefined) {
      this.writeBusy = false;
      return;
    }
    const client = this.gattClient;
    const ch = this.findChar(head.uuid);
    if (client === null || ch === null) {
      head.result?.error('notFound', `特征不存在:${head.uuid}`, null);
      this.flushWrites();
      return;
    }
    this.writeBusy = true;
    const buf = new ArrayBuffer(head.data.byteLength);
    const v = new Uint8Array(buf);
    for (let i = 0; i < head.data.byteLength; i++) {
      v[i] = head.data[i];
    }
    const obj: ble.BLECharacteristic = {
      serviceUuid: SVC,
      characteristicUuid: head.uuid,
      characteristicValue: buf,
      descriptors: [],
    };
    const c = client as Object as Record<string, Function>;
    try {
      // 第二参 1 = WRITE(带响应);相机拒写以此回错(Dart 侧转异常)
      c['writeCharacteristicValue'](obj, 1, (err: BusinessError): void => {
        this.writeBusy = false;
        if (err) {
          Log.w(TAG, `write ${head.uuid}: ${err.code} ${err.message}`);
          head.result?.error('writeFailed', `${err.message}`, null);
        } else {
          head.result?.success(null);
        }
        this.flushWrites();
      });
    } catch (e) {
      this.writeBusy = false;
      head.result?.error('writeFailed', `${JSON.stringify(e)}`, null);
      this.flushWrites();
    }
  }

  private disconnectNative(): void {
    this.teardownGatt();
  }

  private teardownGatt(): void {
    if (this.mtuTimerId !== -1) {
      clearTimeout(this.mtuTimerId);
      this.mtuTimerId = -1;
    }
    this.discoveryInFlight = false;
    this.discoveryDone = false;
    if (this.gattClient !== null) {
      try {
        this.gattClient.disconnect();
        this.gattClient.close();
      } catch (e) {
        Log.w(TAG, `teardown: ${e}`);
      }
      this.gattClient = null;
    }
    // 队列里的写全部落错(Dart 侧转异常,会话层已有缓存重发兜底)
    for (const p of this.writeQueue) {
      p.result?.error('disconnected', '连接已断开', null);
    }
    this.writeQueue = [];
    this.writeBusy = false;
    this.charMap.clear();
    this.propsMap.clear();
  }

  // ------------------------------------------------------------------
  // 程序化经典蓝牙绑定(鸿蒙独有;iOS 无此 API 只能引导系统设置页)
  // ------------------------------------------------------------------

  private bondDevice(deviceId: string, name: string, serial: string,
    result: MethodResult): void {
    let matched = false;
    let bonded = false;
    const discoverCb = (data: Object): void => {
      if (matched) {
        return;
      }
      const devs = Array.isArray(data) ? data as Object[] : [data];
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i] as Record<string, Object>;
        const dName = (d['deviceName'] as string) ?? '';
        const addr = (d['deviceId'] as string) ?? '';
        if (dName === '' || addr === '') {
          continue;
        }
        // 匹配:经典名 ≈ BLE 名(下划线归一)或含序列号 —— 防误配
        const norm = (s: string): string =>
          s.replace(/_/g, '').toLowerCase();
        const hit = (name !== '' &&
          (norm(dName).includes(norm(name)) || norm(name).includes(norm(dName))))
          || (serial !== '' && norm(dName).includes(serial.replace(/-/g, '').toLowerCase()));
        if (!hit) {
          continue;
        }
        matched = true;
        try {
          connection.stopBluetoothDiscovery();
        } catch (e) {
          Log.w(TAG, `stopDiscovery: ${e}`);
        }
        Log.i(TAG, `bond: matched ${dName} ${addr}`);
        try {
          connection.pairDevice(addr);
        } catch (e) {
          Log.e(TAG, `pairDevice: ${JSON.stringify(e)}`);
          result.error('bondFailed', '配对请求失败', null);
          return;
        }
        const stateCb = (bond: connection.BondStateParam): void => {
          if (bond.deviceId !== addr || bonded) {
            return;
          }
          this.emit({
            'type': 'bond', 'state': bond.state as number,
            'uuid': addr, 'name': dName,
          });
          if (bond.state === connection.BondState.BOND_STATE_BONDED) {
            bonded = true;
            connection.off('bondStateChange', stateCb);
            result.success(true);
          } else if (bond.state !== connection.BondState.BOND_STATE_BONDING) {
            bonded = true;
            connection.off('bondStateChange', stateCb);
            result.error('bondRejected', '配对被拒绝或失败', null);
          }
        };
        connection.on('bondStateChange', stateCb);
        setTimeout((): void => {
          if (!bonded) {
            bonded = true;
            connection.off('bondStateChange', stateCb);
            result.error('bondTimeout', '绑定响应超时', null);
          }
        }, 20000);
        return;
      }
    };
    try {
      connection.on('discoveryResult', discoverCb);
      connection.startBluetoothDiscovery();
    } catch (e) {
      Log.e(TAG, `bond discovery: ${JSON.stringify(e)}`);
      result.error('bondFailed', '经典蓝牙发现启动失败', null);
      return;
    }
    setTimeout((): void => {
      if (!matched) {
        try {
          connection.off('discoveryResult', discoverCb);
          connection.stopBluetoothDiscovery();
        } catch (e) {
          Log.w(TAG, `bond timeout cleanup: ${e}`);
        }
        result.error('bondNotFound', '未发现相机(须先断开 BLE,相机才暴露经典蓝牙)', null);
      }
    }, 15000);
  }

  // ------------------------------------------------------------------

  private emit(payload: Record<string, Object>): void {
    this.sink?.success(payload);
  }
}
