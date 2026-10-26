/**
 * NikonPill USB 主机通道(ohos 平台,native 侧)。
 *
 * 对应 Dart 契约 lib/platform/usb/usb_host.dart(v2 字节管道):
 * - bulkRead(maxLen, timeoutMs):单次读、短读合法,native 不做容器重组
 *   (容器头解析/按长度补齐在 Dart 的 UsbPtpTransport;GetObject 25.6MB
 *   单容器不能整体过通道驻留内存);
 * - 窗口内无数据 → PlatformException code 'usb_timeout'(Dart 映射
 *   TimeoutException);
 * - bulkOut:native 内部 16KB 分块循环写;
 * - drainIn:中止/开链后的有界冲刷 —— 清超读暂存 + 300ms 静默窗循环吸干
 *   bulk IN 残余(无它则中止事务的残留字节毒化后续事务,流错位自锁死);
 * - interrupt 事件走 EventChannel,完整事件容器(≤64B)由本文件重组
 *   (12B 头 + u32 长度驱动)。
 *
 * ohos API 要点(@ohos.usbManager,DevEco 6.1.1 / apiVersion 24,真机实测):
 * - bulkTransfer(pipe, endpoint, Uint8Array, timeout) 为 Promise 异步,
 *   不阻塞主线程;返回传输字节数,-1 异常,timeout=0 表示无限等待;
 * - libusb 层的读请求长度必须 ≥ 单个事务突发数据量:请求 12B 容器头
 *   而相机整只 DATA 容器(~180B)到达时,以 babble 报
 *   LIBUSB_ERROR_OVERFLOW(-8)—— bulkRead 内部按 ≥16KB、64KB 起步
 *   自适应探大至 ≤128KB 读入(阶梯实测:256KB 挂死、1MB 恒 rc=-1,
 *   2026-10-25 定案;AIMD 见 bulkInReadBytes 注),超出 maxLen 的字节
 *   暂存,下次调用先掏暂存(对 Dart 是普通短读流);
 * - usbControlTransfer 的 controlParam **必须带 data 属性**(运行时
 *   401,比 d.ts 严格):零长 OUT 请求也要传 data: new Uint8Array(0);
 * - 上轮失败会在设备侧留下脏状态:OUT 端点 data toggle 停在 DATA1,
 *   重新 claim 不复位 → 后续写全被丢(ret=-7 超时)。USB 2.0 规范:
 *   ClearFeature(ENDPOINT_HALT) 无条件把两端 toggle 重置回 DATA0,
 *   open 成功后对两个 bulk 端点各做一次(顺带冲掉 IN 端点残数据);
 * - interrupt 端点读取用 bulkTransfer 直投尝试(bulk/interrupt 底层同为
 *   URB 传输);若直投被拒,后备为 usbSubmitTransfer(@since 18,
 *   UsbDataTransferParams.type=TRANSFER_TYPE_INTERRUPT 的异步提交),
 *   v1 主线不依赖事件流(事件仅拍摄检测用);
 * - 无 clearHalt API:STALL 恢复走 usbControlTransfer 手工 CLEAR_FEATURE
 *   (bmRequestType=0x02 OUT|endpoint,bRequest=0x01,wValue=0 ENDPOINT_HALT,
 *   wIndex=端点地址)。
 *
 * 相机侧(Zf 真机实测,但代码不写死,按描述符枚举):
 * STI 接口 class 6,bulk IN 0x81 / bulk OUT 0x02 / interrupt IN 0x83,
 * interrupt wMaxPacketSize=8(事件 16B 会跨包,native 重组处理)。
 */
import usb from '@ohos.usbManager';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  EventChannel,
  EventSink,
  Log,
} from '@ohos/flutter_ohos';
import { NativeLog } from '../log/NativeLog';

const TAG = 'UsbHostPlugin';

/// 尼康 USB Vendor ID(USB-IF 分配)。
const NIKON_VENDOR_ID = 0x04B0;

/// USB Still Image class(PTP)。STI 接口按描述符枚举,不写死接口号。
const USB_CLASS_STILL_IMAGE = 6;

/// 端点传输类型(d.ts UsbEndpointTransferType:0x2=bulk,0x3=interrupt)。
const ENDPOINT_TYPE_BULK = 0x2;
const ENDPOINT_TYPE_INTERRUPT = 0x3;
/// 端点方向(d.ts USBRequestDirection:0x80=IN,0=OUT)。
const ENDPOINT_DIR_IN = 0x80;

/// CLEAR_FEATURE 控制请求(bmRequestType 0x02 = OUT|standard|endpoint)。
const USB_REQUEST_TARGET_ENDPOINT = 0x02;
const USB_REQUEST_CLEAR_FEATURE = 0x01;
const ENDPOINT_HALT = 0x0000;

/// bulkOut 内部分块。
const BULK_OUT_CHUNK_BYTES = 16 * 1024;
/// bulkOut 整体超时(命令/数据出相位,相机不会长时间拒收)。
const BULK_OUT_TIMEOUT_MS = 5000;

/// bulk IN 单次 libusb 读的下限:必须 ≥ 一个事务突发的数据量
/// (真机实测:请求 12B 容器头,相机整只 ~180B DATA 容器到达 →
/// babble → LIBUSB_ERROR_OVERFLOW -8)。超出 maxLen 的字节进 leftover。
const BULK_IN_MIN_READ_BYTES = 16 * 1024;

/// bulk IN 子块读尺寸(AIMD,见 bulkInReadBytes 注):起步 64KB =
/// 2026-09-27 真机闭环实测安全粒度(当时通道往返即 64KB/次,吞吐
/// 3.7-4.5MB/s);1MB 整缓冲直读真机恒 rc=-1(2026-10-25 定案,
/// 详见 fix 提交)。
const BULK_IN_READ_BYTES_START = 64 * 1024;

/// bulk IN 子块读尺寸上限:128KB(2026-10-25 真机阶梯实测:64KB ✓、
/// 128KB ✓、**256KB 挂死**—— Promise 永不返回,读超时窗对其无效,
/// 看门狗 21s 掐链重连后重置重探再挂 = 无限卡死循环(用户实证「下载
/// 到 2M 就卡死」,卡点 = 升档 256KB 的首笔读);1MB 秒拒 rc=-1)。
/// 故封顶钉在实测安全档,不探入未知区;吞吐 ≈ 128KB ÷ 单次开销 ~9ms
/// ≈ 13-14MB/s。要再上去得换路(usbSubmitTransfer 异步流水/原生肖块),
/// 等有 SDK 通路再说。
const BULK_IN_READ_BYTES_MAX = 128 * 1024;

/// drainIn 单轮静默窗:一轮内无数据即认为吸干(Android 同口径 300ms)。
const DRAIN_QUIET_MS = 300;
/// drainIn 轮数上限:数据持续到达也最多吸 32 轮(有界,别无限等;
/// 残余超过此量的极端只能靠上层断链重连兜底)。
const DRAIN_MAX_ROUNDS = 32;

/// interrupt 事件缓冲:PTP 事件容器 ≤64B(Zf 实测 12/16B)。
const INTERRUPT_BUF_BYTES = 64;

/** 打开会话:设备、管道、接口与三个端点。 */
class UsbSession {
  device: usb.USBDevice;
  pipe: usb.USBDevicePipe;
  iface: usb.USBInterface;
  bulkIn: usb.USBEndpoint;
  bulkOut: usb.USBEndpoint;
  interruptIn: usb.USBEndpoint | null;

  constructor(device: usb.USBDevice, pipe: usb.USBDevicePipe, iface: usb.USBInterface,
    bulkIn: usb.USBEndpoint, bulkOut: usb.USBEndpoint, interruptIn: usb.USBEndpoint | null) {
    this.device = device;
    this.pipe = pipe;
    this.iface = iface;
    this.bulkIn = bulkIn;
    this.bulkOut = bulkOut;
    this.interruptIn = interruptIn;
  }
}

/**
 * interrupt IN 字节流 → PTP 事件容器 重组器。
 * 12B 头:u32 总长(含头)+ u16 type + u16 code + u32 txid;
 * 长度字段驱动补齐,凑齐一个完整容器就上抛一个。
 * 畸形(长度 <12 或 >64)时丢弃缓冲重新同步(事件流允许丢帧,不断流)。
 */
class InterruptAssembler {
  private pending: Uint8Array = new Uint8Array(0);

  reset(): void {
    this.pending = new Uint8Array(0);
  }

  push(bytes: Uint8Array, emit: (frame: Uint8Array) => void): void {
    const merged = new Uint8Array(this.pending.length + bytes.length);
    merged.set(this.pending, 0);
    merged.set(bytes, this.pending.length);
    this.pending = merged;
    while (this.pending.length >= 12) {
      const len = this.u32le(0);
      if (len < 12 || len > 64) {
        Log.w(TAG, `事件容器长度畸形 len=${len},丢弃缓冲重新同步`);
        this.pending = new Uint8Array(0);
        return;
      }
      if (this.pending.length < len) {
        break; // 头已到,体未齐,等下一包
      }
      emit(this.pending.slice(0, len));
      this.pending = this.pending.slice(len);
    }
  }

  private u32le(offset: number): number {
    return this.pending[offset] | (this.pending[offset + 1] << 8) |
      (this.pending[offset + 2] << 16) | (this.pending[offset + 3] << 24);
  }
}

/** `nikonpill/usb` + `nikonpill/usb/events` 通道实现。 */
export class UsbHostPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private session: UsbSession | null = null;
  private pollStopped = true;
  private assembler: InterruptAssembler = new InterruptAssembler();
  /// bulk IN 超读余量(≥maxLen 之外的突发字节),下次 bulkRead 先掏这里。
  private bulkInLeftover: Uint8Array = new Uint8Array(0);

  /// bulk IN 子块读尺寸(AIMD 自适应,会话内跨调用记忆):起步 64KB
  /// (实测安全粒度),一次通道调用全程满块收满(saturated)后 ×2 探大,
  /// 上限 128KB(256KB 挂死实证,见常量注);负值回退并把该尺寸记入
  /// 坏档(≥ bulkInBadFrom 不再试)。
  /// 为什么自适应:bulkTransfer 单次固定开销 ~9ms 不随尺寸摊薄,
  /// 吞吐 = 尺寸/开销,64KB 档顶死 ~7MB/s;128KB 档 ≈ 13-14MB/s。
  private bulkInReadBytes: number = BULK_IN_READ_BYTES_START;
  /// 最小已知坏档尺寸(此值及以上不再尝试;MAX_SAFE_INTEGER = 尚无)。
  private bulkInBadFrom: number = Number.MAX_SAFE_INTEGER;

  getUniqueClassName(): string {
    return 'UsbHostPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nikonpill/usb');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onMethodCall(call, result);
      },
    });
    this.events = new EventChannel(binding.getBinaryMessenger(), 'nikonpill/usb/events');
    this.events.setStreamHandler({
      onListen: (args: ESObject, events: EventSink): void => {
        this.sink = events;
        // 惰性轮询:只有 Dart 订阅了事件流才碰 interrupt 端点,
        // 避免与 bulk 主线并发传输的不确定性(主线 P0 不订阅,零风险)。
        this.startInterruptPoll();
      },
      onCancel: (): void => {
        this.sink = null;
        this.pollStopped = true;
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.events = null;
    this.sink = null;
    this.teardownSession();
  }

  private onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'listCameras':
        this.listCameras(result);
        break;
      case 'open':
        this.open(call.argument('identifier') as string, result);
        break;
      case 'bulkOut':
        this.bulkOut(call.argument('bytes') as Uint8Array, result);
        break;
      case 'bulkRead':
        this.bulkRead(call.argument('maxLen') as number, call.argument('timeoutMs') as number, result);
        break;
      case 'drainIn':
        this.drainIn(result);
        break;
      case 'close':
        this.teardownSession();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// 枚举尼康相机(VID 0x04B0);未插入或无权限返回空表。
  private listCameras(result: MethodResult): void {
    const out: Array<Record<string, Object>> = [];
    try {
      for (const dev of usb.getDevices()) {
        if (dev.vendorId === NIKON_VENDOR_ID) {
          out.push({
            'vendorId': dev.vendorId,
            'productId': dev.productId,
            'identifier': `${dev.busNum}-${dev.devAddress}`,
          } as Record<string, Object>);
        }
      }
      result.success(out);
    } catch (e) {
      result.error('usb_error', `getDevices: ${e}`, null);
    }
  }

  /// 打开并独占 Still Image 接口:requestRight(系统授权框)→ connectDevice →
  /// claimInterface(STI 按描述符枚举)→ 端点按 type/direction 分拣。
  private async open(identifier: string, result: MethodResult): Promise<void> {
    this.teardownSession();

    let device: usb.USBDevice | null = null;
    try {
      for (const dev of usb.getDevices()) {
        if (`${dev.busNum}-${dev.devAddress}` === identifier) {
          device = dev;
          break;
        }
      }
    } catch (e) {
      result.error('usb_error', `getDevices: ${e}`, null);
      return;
    }
    if (device === null) {
      result.error('usb_error', `device not found: ${identifier}`, null);
      return;
    }

    let granted = false;
    try {
      granted = await usb.requestRight(device.name);
    } catch (e) {
      Log.w(TAG, `requestRight: ${e}`);
      granted = false;
    }
    if (!granted) {
      result.error('usb_denied', '用户未授权 USB 访问', null);
      return;
    }

    // STI 接口:优先 class 6;后备:含 bulk IN/OUT 双端点的接口。
    let iface: usb.USBInterface | null = null;
    let fallback: usb.USBInterface | null = null;
    for (const cfg of device.configs) {
      for (const i of cfg.interfaces) {
        if (i.clazz === USB_CLASS_STILL_IMAGE) {
          iface = i;
          break;
        }
        if (fallback === null) {
          let hasBulkIn = false;
          let hasBulkOut = false;
          for (const ep of i.endpoints) {
            if (ep.type === ENDPOINT_TYPE_BULK && ep.direction === ENDPOINT_DIR_IN) {
              hasBulkIn = true;
            } else if (ep.type === ENDPOINT_TYPE_BULK && ep.direction !== ENDPOINT_DIR_IN) {
              hasBulkOut = true;
            }
          }
          if (hasBulkIn && hasBulkOut) {
            fallback = i;
          }
        }
      }
      if (iface !== null) {
        break;
      }
    }
    iface = iface ?? fallback;
    if (iface === null) {
      result.error('usb_error', 'Still Image 接口未找到', null);
      return;
    }

    let bulkIn: usb.USBEndpoint | null = null;
    let bulkOut: usb.USBEndpoint | null = null;
    let interruptIn: usb.USBEndpoint | null = null;
    for (const ep of iface.endpoints) {
      if (ep.type === ENDPOINT_TYPE_BULK && ep.direction === ENDPOINT_DIR_IN) {
        bulkIn = ep;
      } else if (ep.type === ENDPOINT_TYPE_BULK && ep.direction !== ENDPOINT_DIR_IN) {
        bulkOut = ep;
      } else if (ep.type === ENDPOINT_TYPE_INTERRUPT && ep.direction === ENDPOINT_DIR_IN) {
        interruptIn = ep;
      }
    }
    if (bulkIn === null || bulkOut === null) {
      result.error('usb_error', 'bulk IN/OUT 端点未找到', null);
      return;
    }

    const pipe = usb.connectDevice(device);
    const rc = usb.claimInterface(pipe, iface, true);
    if (rc !== 0) {
      try {
        usb.closePipe(pipe);
      } catch (e) {
        Log.w(TAG, `close after claim failure: ${e}`);
      }
      result.error('usb_error', `claimInterface rc=${rc}`, null);
      return;
    }

    Log.i(TAG, `open: iface=${iface.id} bulkIn=0x${bulkIn.address.toString(16)} ` +
      `bulkOut=0x${bulkOut.address.toString(16)}` +
      (interruptIn !== null ? ` interruptIn=0x${interruptIn.address.toString(16)}` : ' interruptIn=无'));
    this.session = new UsbSession(device, pipe, iface, bulkIn, bulkOut, interruptIn);
    // 自适应子块读状态随链路重置:新管道重探(升级在前几个满块调用内
    // 完成,代价可忽略),旧会话的坏档记号不作数。
    this.bulkInReadBytes = BULK_IN_READ_BYTES_START;
    this.bulkInBadFrom = Number.MAX_SAFE_INTEGER;
    // 上轮失败会在设备侧留下脏状态(OUT toggle 停在 DATA1 → 后续写全被
    // 丢,真机实测 ret=-7 超时;IN 端点可能还压着未读残数据)。USB 2.0:
    // ClearFeature(ENDPOINT_HALT) 无条件把两端 data toggle 重置回 DATA0。
    // clearHalt 内部自吞错误(尽力而为,失败不阻断 open)。
    await this.clearHalt(bulkIn.address);
    await this.clearHalt(bulkOut.address);
    // 开链排空:clearHalt 只复位 toggle,宿主侧已收进 SDK 暂存/设备端点
    // FIFO 的上链残余它够不着 —— 上一链中止事务的残留容器会喂给新链第
    // 一条事务,连接恒报「容器 txid=A 与事务 B 不符(流错位?)」且每次
    // 失败连接自身的中止又添新残留,自锁死(2026-10-26 真机实证)。
    // 开链后必无合法在途数据,有即残留,吸到静默为止。
    const opened = this.session;
    if (opened !== null) {
      const drained = await this.drainBulkIn(opened, DRAIN_QUIET_MS);
      if (drained > 0) {
        Log.w(TAG, `open 吸干上链残余 ${drained}B(新链从干净流开始)`);
      }
    }
    // 先订阅后连接的场景:打开成功时若事件流已在监听,这里补启动轮询
    if (this.sink !== null) {
      this.startInterruptPoll();
    }
    result.success(null);
  }

  /// bulk OUT:native 内部 16KB 分块;-1 时 CLEAR_FEATURE 后重试一次
  /// (相机以 STALL 表达流控是正常现象,不得当错误上抛)。
  private async bulkOut(bytes: Uint8Array, result: MethodResult): Promise<void> {
    const s = this.session;
    if (s === null) {
      result.error('usb_closed', '会话未打开', null);
      return;
    }
    try {
      for (let off = 0; off < bytes.length; off += BULK_OUT_CHUNK_BYTES) {
        const end = Math.min(off + BULK_OUT_CHUNK_BYTES, bytes.length);
        const chunk = bytes.slice(off, end);
        let n = await usb.bulkTransfer(s.pipe, s.bulkOut, chunk, BULK_OUT_TIMEOUT_MS);
        if (n < 0) {
          Log.w(TAG, `bulkOut rc=${n},CLEAR_FEATURE 后重试`);
          await this.clearHalt(s.bulkOut.address);
          n = await usb.bulkTransfer(s.pipe, s.bulkOut, chunk, BULK_OUT_TIMEOUT_MS);
          if (n < 0) {
            NativeLog.e('usb', `bulkOut 失败:rc=${n}(共 ${bytes.length}B,已写 ${off}B)`);
            result.error('usb_error', `bulkTransfer out rc=${n}`, null);
            return;
          }
        }
      }
      // 会话轮换守卫:等待期间 teardown/重连会让 s 的 pipe 失效。
      // 对应的 Dart 调用早已被看门狗判超时遗弃;应答只为释放通道。
      if (this.session !== s) {
        result.error('usb_stale', '会话已轮换,旧链路写结果丢弃', null);
        return;
      }
      result.success(null);
    } catch (e) {
      result.error('usb_error', `bulkOut: ${e}`, null);
    }
  }

  /// bulk IN:单次通道调用读满 maxLen(短读/ZLB 即返),Dart 契约不变;
  /// native 内部按自适应子块(bulkInReadBytes,64KB 起步探大至 512KB)
  /// 循环请求并组装。
  /// - 单次请求下限 ≥[BULK_IN_MIN_READ_BYTES](防 OVERFLOW babble,同旧),
  ///   尺寸自适应(AIMD,见 bulkInReadBytes 注 —— 单次开销 ~9ms 固定,
  ///   提尺寸是吞吐唯一杠杆;256KB 挂死/1MB rc=-1 故封 128KB);
  /// - 超出 maxLen 的字节暂存 leftover,下次调用先掏(对 Dart 是普通
  ///   短读流);
  /// - 空手负值:rc=-1 且子块尺寸可回退时先回退重读(预提交拒收零字节
  ///   损耗,每调用一探);否则 CLEAR_FEATURE 后原地重读一次(Android
  ///   同款:STALL 是相机流控,负值分不清 STALL 与超时 —— STALL 即时
  ///   失败、超时吃满窗,窗口尚有余量才值得重试);有部分数据则优先
  ///   交付短读。
  private async bulkRead(maxLen: number, timeoutMs: number, result: MethodResult): Promise<void> {
    const s = this.session;
    if (s === null) {
      result.error('usb_closed', '会话未打开', null);
      return;
    }
    if (maxLen <= 0) {
      result.error('usb_error', `bulkRead maxLen=${maxLen} 非正`, null);
      return;
    }
    try {
      if (this.bulkInLeftover.length > 0) {
        const take = Math.min(maxLen, this.bulkInLeftover.length);
        const out = this.bulkInLeftover.slice(0, take);
        this.bulkInLeftover = this.bulkInLeftover.slice(take);
        result.success(out);
        return;
      }
      const buffer = new Uint8Array(maxLen);
      let scratch = new Uint8Array(
        Math.min(Math.max(maxLen, BULK_IN_MIN_READ_BYTES), this.bulkInReadBytes));
      const finite = timeoutMs > 0;
      const start = Date.now();
      const deadline = start + timeoutMs;
      let filled = 0;
      let haltRetried = false;
      let lastRc = 0;
      let saturated = true; // 本调用全程满块收满(探大判据)
      while (filled < maxLen) {
        if (finite && deadline - Date.now() <= 0) {
          break; // 窗口耗尽:有数据交付短读,无数据走超时
        }
        // 下限 1ms:窗内剩余若传 0 会变成无限等待,绝不可传 0。
        const wait = finite ? Math.max(1, deadline - Date.now()) : 0;
        const n = await usb.bulkTransfer(s.pipe, s.bulkIn, scratch, wait);
        lastRc = n;
        if (n > 0) {
          const take = Math.min(n, maxLen - filled);
          buffer.set(scratch.subarray(0, take), filled);
          filled += take;
          if (take < n) {
            // 超读余量(小 maxLen 撞上大突发;仅此一次,take<n 即已满格)
            this.bulkInLeftover = scratch.slice(take, n);
            saturated = false;
          }
          if (n < scratch.length) {
            saturated = false;
            break; // 短读 = 突发结束
          }
          continue; // 满块继续组装
        }
        if (n === 0) {
          // 零长包:传输边界标记(容器恰为 wMaxPacketSize 整数倍时出现),
          // 真数据在下一个传输里。
          saturated = false;
          if (filled > 0) break; // 交付
          continue; // 未见数据的 ZLB:耗窗口续等
        }
        // 负值:rc=-1 且子块尺寸可回退 → 逐级折半重读(服务预提交拒收
        // 特征码,1MB 档实测恒 -1,零字节损耗;若 256KB 也拒就一路退回
        // 64KB 实测安全档,失败尺寸逐档记坏);否则 CLEAR_FEATURE 原地
        // 重读一次(STALL 是相机流控,负值分不清 STALL 与超时,窗口已尽
        // 不再重试);已有部分数据则优先交付。
        if (filled === 0 && n === -1 && scratch.length > BULK_IN_READ_BYTES_START) {
          this.bulkInBadFrom = Math.min(this.bulkInBadFrom, scratch.length);
          this.bulkInReadBytes = Math.max(BULK_IN_READ_BYTES_START, scratch.length >> 1);
          scratch = new Uint8Array(
            Math.min(Math.max(maxLen, BULK_IN_MIN_READ_BYTES), this.bulkInReadBytes));
          saturated = false;
          continue;
        }
        if (filled === 0 && !haltRetried && (!finite || deadline - Date.now() > 0)) {
          haltRetried = true;
          saturated = false;
          Log.w(TAG, `bulkRead rc=${n},CLEAR_FEATURE 后原地重读`);
          await this.clearHalt(s.bulkIn.address);
          continue;
        }
        if (filled > 0) break;
        saturated = false;
        NativeLog.e('usb', `bulkRead 失败:rc=${n}(max=${maxLen}B,窗=${timeoutMs}ms,实耗=${Date.now() - start}ms)`);
        if (finite) {
          // 窗口内无数据:对齐 Dart 的 TimeoutException 语义
          result.error('usb_timeout', `bulkTransfer rc=${n} within ${timeoutMs}ms`, null);
        } else {
          result.error('usb_error', `bulkTransfer rc=${n}`, null);
        }
        return;
      }
      // 会话轮换守卫(关键):等待期间 teardown/重连会让 s 的 pipe 失效,
      // 而晚到的数据绝不能进 this.bulkInLeftover —— leftover 是共享字段,
      // 旧链路的字节会污染**新会话**的读流。对应的 Dart 调用早已被看门狗
      // 判超时遗弃;应答只为释放通道。
      if (this.session !== s) {
        result.error('usb_stale', '会话已轮换,旧链路读结果丢弃', null);
        return;
      }
      if (saturated && filled === maxLen) {
        // 全程满块收满 = 流连续:×2 探大(顶到上限/坏档线为止),下次
        // 调用生效。读请求尺寸对相机不可见(主机 NAK 节拍),协议无感。
        const next = this.bulkInReadBytes << 1;
        if (next <= BULK_IN_READ_BYTES_MAX && next < this.bulkInBadFrom) {
          this.bulkInReadBytes = next;
        }
      }
      if (filled > 0) {
        result.success(buffer.slice(0, filled));
        return;
      }
      NativeLog.e('usb', `bulkRead 失败:rc=${lastRc}(max=${maxLen}B,窗=${timeoutMs}ms,实耗=${Date.now() - start}ms)`);
      if (finite) {
        // 窗口内无数据(-1/0):对齐 Dart 的 TimeoutException 语义
        result.error('usb_timeout', `bulkTransfer rc=${lastRc} within ${timeoutMs}ms`, null);
      } else {
        result.error('usb_error', `bulkTransfer rc=${lastRc}`, null);
      }
    } catch (e) {
      NativeLog.e('usb', `bulkRead 异常:${e}`);
      result.error('usb_error', `bulkRead: ${e}`, null);
    }
  }

  /// bulk IN 有界冲刷:吸干残余字节,下一事务不从错位字节开始(nico/
  /// Android 同款)。残余两处来源都要收:native 超读暂存(bulkInLeftover,
  /// 属被中止事务,先丢)+ 相机仍在吐的数据相位字节(静默窗循环吸到
  /// 静默为止)。子块尺寸取当前自适应档与 16KB 下限的较大者 —— 小缓冲
  /// 撞大突发会 babble 报 -8,被误判成静默提前收工,残留吸不尽。
  /// 不碰 AIMD 状态(冲刷读不参与升/降档)。返回吸干字节数(仅日志价值)。
  private async drainBulkIn(s: UsbSession, quietMs: number): Promise<number> {
    this.bulkInLeftover = new Uint8Array(0);
    const scratch =
      new Uint8Array(Math.max(BULK_IN_MIN_READ_BYTES, this.bulkInReadBytes));
    let drained = 0;
    for (let rounds = 0; rounds < DRAIN_MAX_ROUNDS; rounds++) {
      let n = 0;
      try {
        n = await usb.bulkTransfer(s.pipe, s.bulkIn, scratch, quietMs);
      } catch (e) {
        Log.w(TAG, `drain bulkTransfer 异常:${e}`);
        break;
      }
      if (n < 0) {
        break; // 静默窗内无数据:已吸干
      }
      drained += n; // n==0(ZLB)也耗一轮,继续吸
    }
    return drained;
  }

  /// Dart 契约见 UsbBytePipe.drainIn:事务异常收场后的 best-effort 排空。
  /// 冲刷发生在 PtpSession 串行门持有期内,与下一事务天然串行不交错
  /// (Android 同款)。2026-10-26 前 ohos 未实现 → notImplemented 被
  /// Dart 侧 best-effort 静默,中止事务的残余无排空手段 = 流错位自锁死
  /// 的直接根因,补齐对齐 Android。
  private async drainIn(result: MethodResult): Promise<void> {
    const s = this.session;
    if (s === null) {
      result.error('usb_closed', '会话未打开', null);
      return;
    }
    try {
      const drained = await this.drainBulkIn(s, DRAIN_QUIET_MS);
      // 会话轮换守卫:与 bulkRead 同款 —— 旧链路的冲刷结果只释放通道,
      // 不作数(drainBulkIn 里清的 leftover 也随 teardown 重置,无污染)。
      if (this.session !== s) {
        result.error('usb_stale', '会话已轮换,冲刷结果丢弃', null);
        return;
      }
      if (drained > 0) {
        Log.i(TAG, `drainIn 吸干 ${drained}B`);
      }
      result.success(drained);
    } catch (e) {
      NativeLog.e('usb', `drainIn 异常:${e}`);
      result.error('usb_error', `drainIn: ${e}`, null);
    }
  }

  /// STALL 恢复/端点复位:手工 CLEAR_FEATURE 控制请求(ohos 无 clearHalt API)。
  /// 运行时(apiVersion 24)要求 controlParam 必带 data 属性,即使 wLength=0。
  private async clearHalt(endpointAddr: number): Promise<void> {
    const s = this.session;
    if (s === null) {
      return;
    }
    try {
      await usb.usbControlTransfer(s.pipe, {
        bmRequestType: USB_REQUEST_TARGET_ENDPOINT,
        bRequest: USB_REQUEST_CLEAR_FEATURE,
        wValue: ENDPOINT_HALT,
        wIndex: endpointAddr,
        wLength: 0,
        data: new Uint8Array(0),
      } as usb.USBDeviceRequestParams, 0);
    } catch (e) {
      Log.w(TAG, `clearHalt(0x${endpointAddr.toString(16)}): ${e}`);
    }
  }

  /// interrupt 轮询(仅在 Dart 订阅事件流后启动)。
  /// timeout=0 无限等待,避免空转;pipe 关闭后挂着的传输会失败返回。
  private startInterruptPoll(): void {
    const s = this.session;
    if (s === null || s.interruptIn === null || !this.pollStopped) {
      return;
    }
    this.pollStopped = false;
    this.interruptPollLoop();
  }

  private async interruptPollLoop(): Promise<void> {
    const s = this.session;
    if (s === null || s.interruptIn === null) {
      return;
    }
    const endpoint = s.interruptIn;
    Log.i(TAG, 'interrupt 轮询启动(bulkTransfer 直投 interrupt 端点,本 SDK 无 submitTransfer)');
    while (!this.pollStopped && this.session === s && this.sink !== null) {
      const buffer = new Uint8Array(INTERRUPT_BUF_BYTES);
      let n = -1;
      try {
        n = await usb.bulkTransfer(s.pipe, endpoint, buffer, 0);
      } catch (e) {
        n = -1;
      }
      if (this.pollStopped || this.session !== s) {
        break;
      }
      if (n > 0) {
        this.assembler.push(buffer.slice(0, n), (frame: Uint8Array): void => {
          if (this.sink !== null) {
            this.sink.success(frame);
          }
        });
      } else if (n < 0) {
        // 无限等待下仍失败:多半是 bulkTransfer 不接受 interrupt 端点,或 pipe 已坏。
        Log.w(TAG, `interrupt 读失败 rc=${n},停止轮询(事件流不可用,主线不受影响)`);
        break;
      }
      // n === 0:ZLB 空包,继续
    }
    Log.i(TAG, 'interrupt 轮询退出');
  }

  /// 关闭会话(幂等):停轮询 → release → close。
  private teardownSession(): void {
    this.pollStopped = true;
    const s = this.session;
    this.session = null;
    this.assembler.reset();
    this.bulkInLeftover = new Uint8Array(0);
    if (s === null) {
      return;
    }
    try {
      usb.releaseInterface(s.pipe, s.iface);
    } catch (e) {
      Log.w(TAG, `releaseInterface: ${e}`);
    }
    try {
      usb.closePipe(s.pipe);
    } catch (e) {
      Log.w(TAG, `close: ${e}`);
    }
  }
}
