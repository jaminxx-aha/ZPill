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
 *   LIBUSB_ERROR_OVERFLOW(-8)—— 读路分两级:**生产主路 =
 *   usbSubmitTransfer URB 流水(bulkReadPipe,512KB 定档)**,每笔
 *   URB 缓冲即 ≥16KB 下限的天然满足;回落/探针 A/B 的 sync 路 bulkRead
 *   内部按 ≥16KB、64KB 起步自适应探大至 ≤128KB 读入(阶梯实测:256KB
 *   挂死、1MB 恒 rc=-1,2026-10-25 定案;AIMD 见 bulkInReadBytes 注),
 *   超出 maxLen 的字节暂存,下次调用先掏暂存(对 Dart 是普通短读流);
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
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';
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

/// 探针/诊断 hilog 直写(flutter_ohos Log 封装缺省 WARN 闸,info 全吞,
/// Release 真机自驱调试靠这里看;NativeLog 则只进 AppLog 不落 hilog)。
function hlog(msg: string): void {
  hilog.info(0xFF00, TAG, msg);
}

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
/// ≈ 13-14MB/s。**生产读路已切 usbSubmitTransfer 流水(见 PIPE_*/
/// bulkReadPipe),本 AIMD 只兜流水不可用/空闲回落场景。**
const BULK_IN_READ_BYTES_MAX = 128 * 1024;

/// usbSubmitTransfer 回调 status 数值(UsbTransferStatus,libusb 同源
/// ABI:0 COMPLETED / 1 ERROR / 2 TIMED_OUT / 3 CANCELLED / 4 STALL /
/// 5 NO_DEVICE / 6 OVERFLOW)。用数值常量:不依赖老设备 d.ts 是否导出。
const TRANSFER_STATUS_COMPLETED = 0;
const TRANSFER_STATUS_TIMED_OUT = 2;
const TRANSFER_STATUS_CANCELLED = 3;

/// submit 流水线缓冲下限(防 OVERFLOW 同理:一笔 URB 须容下一个突发)。
const PIPE_BUF_MIN_BYTES = 16 * 1024;
/// submit 流水线深度上限(探针阶梯最高 8,留余量;防误配吃爆内存)。
const PIPE_DEPTH_MAX = 16;

/// drainIn 单轮静默窗:一轮内无数据即认为吸干(Android 同口径 300ms)。
const DRAIN_QUIET_MS = 300;
/// drainIn 轮数上限:数据持续到达也最多吸 32 轮(有界,别无限等;
/// 残余超过此量的极端只能靠上层断链重连兜底)。
const DRAIN_MAX_ROUNDS = 32;

/// ===== submit 流水线生产策略(2026-10-26 真机探针 4 轮定案)=====
/// 缺省 URB 缓冲 512KB:d=1 尺寸阶梯 64K=10.6/128K=15.1/256K=17.4/
/// 512K=19.9MB/s,512K 零间隙连下持续 21.8-22.9MB/s(2.5× sync);
/// 1M-2M 未在零间隙验证,4M 两次流错位(垃圾 txid)—— 钉 512K 甜点。
const PIPE_DEFAULT_BUF_BYTES = 512 * 1024;
/// 空闲回落阈值:管道闲置超过此时长,下一笔读回落 sync 路(实测
/// 「下载后 ~500ms 间隙 → 下笔事务相机沉默 15s」病只咬间隙后首笔,
/// sync 路无此病;连续下载零间隙无病)。走完回落笔即回流水。
const PIPE_IDLE_FALLBACK_MS = 1000;

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

/** submit 流水线单笔在途 URB(一槽一笔:缓冲/参数/完成通知)。 */
class PipeSlot {
  buffer: Uint8Array = new Uint8Array(0);
  params: usb.UsbDataTransferParams | null = null;
  promise: Promise<void> = Promise.resolve();
  resolve: () => void = (): void => {};
  /// 回调回填:UsbTransferStatus 数值(见 TRANSFER_STATUS_* 常量;-1 = 未回)。
  status: number = -1;
  actual: number = 0;
}

/** submit 流水线记账(口径:setSubmitPipe 清账到 submitPipeStats 取走之间)。 */
class PipeStats {
  urbs: number = 0;
  bytes: number = 0;
  zlb: number = 0;
  shortReads: number = 0;
  timeouts: number = 0;
  errors: number = 0;
  maxActual: number = 0;
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

  /// ===== submit 流水线(生产读路,探针可 A/B)=====
  /// 缺省开:bulkRead 走 usbSubmitTransfer URB 流水(见 bulkReadPipe):
  /// 恒保 depth 笔读在途,「提交→等完成」串行等待被预提交摊掉 ——
  /// sync 路 128KB 墙(~9ms/次固定开销)的换路。探针 setSubmitPipe
  /// 可关闸回 sync A/B;随 open() 重置为缺省开。
  private pipeEnabled: boolean = true;
  private pipeDepth: number = 1;
  private pipeBufBytes: number = PIPE_DEFAULT_BUF_BYTES;
  private pipeSlots: PipeSlot[] = [];
  private pipeStats: PipeStats = new PipeStats();
  /// 本档开闸时刻(stats 汇总耗时/吞吐用)。
  private pipeStartedAt: number = 0;
  /// 最近一次读活动时刻(任一路径收发都刷新)—— 空闲回落判据。
  private pipeLastActivityMs: number = 0;
  /// 空闲回落 hilog 节流戳(30s 一条,闲置期轮询小事务逐条打点太吵)。
  private pipeLastFallbackLogMs: number = 0;

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
      case 'setSubmitPipe':
        this.setSubmitPipe(call.argument('enabled') as boolean,
          (call.argument('depth') as number) ?? 1,
          (call.argument('bufBytes') as number) ?? (64 * 1024), result);
        break;
      case 'submitPipeStats':
        this.submitPipeStats(result);
        break;
      case 'drainIn':
        this.drainIn(result);
        break;
      case 'probeLog':
        hlog(`[dart] ${call.argument('line') as string}`);
        result.success(null);
        break;
      case 'recoveryReset':
        this.recoveryReset(result);
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

    const line = `open: iface=${iface.id} bulkIn=0x${bulkIn.address.toString(16)} ` +
      `bulkOut=0x${bulkOut.address.toString(16)}` +
      (interruptIn !== null ? ` interruptIn=0x${interruptIn.address.toString(16)}` : ' interruptIn=无');
    Log.i(TAG, line);
    hlog(line);
    this.session = new UsbSession(device, pipe, iface, bulkIn, bulkOut, interruptIn);
    // 自适应子块读状态随链路重置:新管道重探(升级在前几个满块调用内
    // 完成,代价可忽略),旧会话的坏档记号不作数。
    this.bulkInReadBytes = BULK_IN_READ_BYTES_START;
    this.bulkInBadFrom = Number.MAX_SAFE_INTEGER;
    // submit 流水随链路重置:生产缺省开(512K 定档);探针 setSubmitPipe
    // 可 A/B 覆盖,换链后回缺省。
    this.pipeEnabled = true;
    this.pipeDepth = 1;
    this.pipeBufBytes = PIPE_DEFAULT_BUF_BYTES;
    this.pipeSlots = [];
    this.pipeStats = new PipeStats();
    this.pipeLastActivityMs = 0;
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

  /// bulk IN:单次通道调用读满 maxLen(短读/ZLB 即返),Dart 契约不变。
  /// 生产主路 = usbSubmitTransfer URB 流水(bulkReadPipe,512K 定档,
  /// 零间隙持续 22MB/s);**空闲 >1s 或取消沿后首笔回落 sync 路**(实测
  /// 「间隙后首笔 15s 沉默」病只咬流水路,sync 无病),走完回流水。
  /// sync 路(回落/探针 A/B 用):native 内部按自适应子块(bulkInReadBytes,
  /// 64KB 起步探大至 128KB)循环请求并组装。
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
      if (this.pipeEnabled) {
        // 生产读路:URB 预提交流水(消费语义与 sync 对齐,见
        // bulkReadPipe)。空闲超阈值回落 sync 一笔 —— 「下载后间隙 →
        // 下笔事务相机沉默 15s」病只咬间隙后首笔,sync 路实测无病;
        // 走完回落笔即回流水(连续下载零间隙,全程流水)。
        const idle = this.pipeSlots.length === 0 &&
          Date.now() - this.pipeLastActivityMs > PIPE_IDLE_FALLBACK_MS;
        if (!idle) {
          await this.bulkReadPipe(maxLen, timeoutMs, result);
          return;
        }
        // 节流留档:连接闲置期探针/摘出轮询每 ~2s 一笔小事务都会走
        // 回落(设计使然,它们正是死窗的靶子),逐条打点太吵。
        if (Date.now() - this.pipeLastFallbackLogMs > 30000) {
          this.pipeLastFallbackLogMs = Date.now();
          hlog(`pipe 空闲回落 sync 一笔(max=${maxLen})`);
        }
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
        this.pipeLastActivityMs = Date.now(); // 空闲回落笔也算活动
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

  /// ===== submit 流水线探针(usbSubmitTransfer,bulk IN)=====

  /// 开/关闸 + 配置(depth × bufBytes)。开闸沿取消旧在途、清账;
  /// 运行时缺 usbSubmitTransfer(老设备/老系统)报 submit_unsupported。
  private setSubmitPipe(enabled: boolean, depth: number, bufBytes: number,
    result: MethodResult): void {
    if (enabled && typeof usb.usbSubmitTransfer !== 'function') {
      Log.w(TAG, 'usbSubmitTransfer 运行时不可用');
      result.error('submit_unsupported', 'usbSubmitTransfer 不在本设备运行时', null);
      return;
    }
    this.cancelPipeUrbs();
    this.pipeEnabled = enabled;
    this.pipeDepth = Math.max(1, Math.min(depth, PIPE_DEPTH_MAX));
    this.pipeBufBytes = Math.max(PIPE_BUF_MIN_BYTES, bufBytes);
    this.pipeStats = new PipeStats();
    this.pipeStartedAt = enabled ? Date.now() : 0;
    const line = `submitPipe: enabled=${enabled} depth=${this.pipeDepth}` +
      ` buf=${this.pipeBufBytes / 1024}KB`;
    Log.i(TAG, line);
    hlog(line);
    result.success(null);
  }

  /// 取账并清零(探针每档一次;含本档耗时,hilog 同步留档可脱离 App 对账)。
  private submitPipeStats(result: MethodResult): void {
    const s = this.pipeStats;
    const ms = this.pipeStartedAt > 0 ? Date.now() - this.pipeStartedAt : 0;
    const line = `submitPipe stats: urbs=${s.urbs} bytes=${s.bytes} ms=${ms}` +
      ` zlb=${s.zlb} short=${s.shortReads} timeout=${s.timeouts}` +
      ` err=${s.errors} maxActual=${s.maxActual}`;
    Log.i(TAG, line);
    hlog(line);
    const out: Record<string, Object> = {
      'urbs': s.urbs,
      'bytes': s.bytes,
      'ms': ms,
      'zlb': s.zlb,
      'shortReads': s.shortReads,
      'timeouts': s.timeouts,
      'errors': s.errors,
      'maxActual': s.maxActual,
    };
    this.pipeStats = new PipeStats();
    result.success(out);
  }

  /// 提交一笔 bulk IN URB(异步,完成走回调回填槽);失败回 null 并记账。
  /// flags=0(无旗标;SHORT_NOT_OK=0 的枚举值存疑,零位恒安全)。
  private submitIn(s: UsbSession, timeoutMs: number): PipeSlot | null {
    const slot = new PipeSlot();
    slot.buffer = new Uint8Array(this.pipeBufBytes);
    slot.promise = new Promise<void>((resolve): void => {
      slot.resolve = resolve;
    });
    slot.params = {
      devPipe: s.pipe,
      flags: 0,
      endpoint: s.bulkIn.address,
      type: usb.UsbEndpointTransferType.TRANSFER_TYPE_BULK,
      timeout: timeoutMs,
      length: slot.buffer.length,
      callback: (err: BusinessError, data: usb.SubmitTransferCallback): void => {
        if (err) {
          slot.status = 1; // TRANSFER_ERROR
        } else {
          slot.status = data.status;
          slot.actual = data.actualLength;
        }
        slot.resolve();
      },
      userData: new Uint8Array(0),
      buffer: slot.buffer,
      isoPacketCount: 0,
    } as usb.UsbDataTransferParams;
    try {
      usb.usbSubmitTransfer(slot.params);
      return slot;
    } catch (e) {
      this.pipeStats.errors++;
      hlog(`usbSubmitTransfer 异常: ${e}`);
      Log.w(TAG, `usbSubmitTransfer 异常: ${e}`);
      return null;
    }
  }

  /// 等槽完成;窗口尽回 false(槽保持在途,URB 自带超时兜底,下次
  /// 调用先消化它)。头笔 promise 与计时器 race,race 出口必清计时器。
  private waitSlot(slot: PipeSlot, winMs: number, finite: boolean): Promise<boolean> {
    if (!finite) {
      return slot.promise.then((): boolean => true);
    }
    let timer: number = 0;
    const tick = new Promise<boolean>((resolve): void => {
      timer = setTimeout((): void => resolve(false), winMs);
    });
    return Promise.race([slot.promise.then((): boolean => true), tick])
      .then((v: boolean): boolean => {
        clearTimeout(timer);
        return v;
      });
  }

  /// bulkRead 的 submit 流水实现:恒保 depth 笔 URB 在途,头笔完成即
  /// 消费 + 循环顶补发 —— 相机出数与主机收数重叠,sync 路每次调用
  /// ~9ms 的固定开销被预提交摊掉。消费语义对齐 sync bulkRead:短读/
  /// ZLB 交付、超读进 leftover、窗口尽报 usb_timeout、会话轮换报 stale。
  private async bulkReadPipe(maxLen: number, timeoutMs: number,
    result: MethodResult): Promise<void> {
    const s = this.session;
    if (s === null) {
      result.error('usb_closed', '会话未打开', null);
      return;
    }
    const finite = timeoutMs > 0;
    const start = Date.now();
    const deadline = start + timeoutMs;
    const buffer = new Uint8Array(maxLen);
    let filled = 0;
    let callUrbs = 0;
    let zlbRun = 0; // 连续零字节完成计(诊断空转病)
    let recovered = false; // 本调用已做过一次空转恢复
    try {
      while (filled < maxLen) {
        if (finite && deadline - Date.now() <= 0) {
          break; // 窗口耗尽:有数据交付短读,无数据走超时
        }
        // 空转恢复实验:URB 恒「完成」却 0 字节(v2 真机 d≥2 实证,
        // 无错无超时)→ cancel + clearHalt(IN) + 重投,看能否救活;
        // 复发即弃窗(别把窗口烧在死循环上)。
        if (zlbRun >= 32 && filled === 0) {
          if (recovered) {
            hlog(`pipe spin 复发(zlb=${zlbRun}),弃窗`);
            break;
          }
          recovered = true;
          hlog(`pipe spin 恢复尝试: cancel + clearHalt + 重投`);
          this.cancelPipeUrbs();
          await this.clearHalt(s.bulkIn.address);
          if (this.session !== s) {
            result.error('usb_stale', '会话已轮换,旧链路读结果丢弃', null);
            return;
          }
          zlbRun = 0;
          continue;
        }
        // 补满在途(头笔消费沿补发,这里兜底凑齐)
        while (this.pipeSlots.length < this.pipeDepth) {
          const win = finite ? Math.max(1, deadline - Date.now()) : 0;
          const slot = this.submitIn(s, win);
          if (slot === null) {
            break;
          }
          this.pipeSlots.push(slot);
        }
        if (this.pipeSlots.length === 0) {
          break; // 一笔都发不出:提交不可用,交失败收尾
        }
        const head = this.pipeSlots[0];
        const win = finite ? Math.max(1, deadline - Date.now()) : 0;
        const done = await this.waitSlot(head, win, finite);
        if (this.session !== s) {
          result.error('usb_stale', '会话已轮换,旧链路读结果丢弃', null);
          return;
        }
        if (!done) {
          break; // 窗口尽:头笔仍在途(自带超时),按已有数据收
        }
        this.pipeSlots.shift();
        this.pipeStats.urbs++;
        callUrbs++;
        this.pipeLastActivityMs = Date.now();
        const n = head.actual;
        if (head.status === TRANSFER_STATUS_COMPLETED && n > 0) {
          zlbRun = 0;
          const take = Math.min(n, maxLen - filled);
          buffer.set(head.buffer.subarray(0, take), filled);
          filled += take;
          if (take < n) {
            // 超读余量(小 maxLen 撞大缓冲,仅头笔撞满格时出现)
            this.bulkInLeftover = head.buffer.slice(take, n);
          }
          this.pipeStats.bytes += take;
          if (this.pipeStats.maxActual < n) {
            this.pipeStats.maxActual = n;
          }
          if (n < head.buffer.length) {
            this.pipeStats.shortReads++;
            break; // 短读 = 突发暂停,先交付(其余在途留给下次调用)
          }
          continue; // 满块:循环顶补发
        }
        if (head.status === TRANSFER_STATUS_COMPLETED && n === 0) {
          this.pipeStats.zlb++;
          zlbRun++;
          if (zlbRun === 4 || zlbRun % 100 === 0) {
            hlog(`pipe ZLB 连转 run=${zlbRun} filled=${filled}`);
          }
          if (filled > 0) {
            break; // 交付
          }
          continue; // 未见数据的 ZLB:续等
        }
        if (head.status === TRANSFER_STATUS_TIMED_OUT) {
          this.pipeStats.timeouts++;
          hlog(`pipe URB TIMED_OUT (filled=${filled})`);
        } else if (head.status !== TRANSFER_STATUS_CANCELLED) {
          this.pipeStats.errors++;
          hlog(`pipe URB status=${head.status} (filled=${filled})`);
          Log.w(TAG, `pipe URB status=${head.status}`);
        }
        break; // TIMED_OUT/CANCELLED/ERROR:有数据交付,无数据走收尾
      }
      if (filled === 0) {
        hlog(`pipe read 异常收口: max=${maxLen} filled=${filled} urbs=${callUrbs}` +
          ` ms=${Date.now() - start} zlbRun=${zlbRun} recovered=${recovered}`);
      }
      if (filled > 0) {
        result.success(buffer.slice(0, filled));
        return;
      }
      if (this.pipeSlots.length === 0 && this.pipeStats.errors > 0) {
        result.error('usb_error', 'submitPipe 提交失败(异常/能力缺)', null);
        return;
      }
      if (finite) {
        result.error('usb_timeout', `submitPipe bulkRead ${timeoutMs}ms 内无数据`, null);
      } else {
        result.error('usb_error', 'submitPipe bulkRead 失败(无数据)', null);
      }
    } catch (e) {
      NativeLog.e('usb', `bulkReadPipe 异常:${e}`);
      result.error('usb_error', `bulkReadPipe: ${e}`, null);
    }
  }

  /// 取消全部在途 URB(teardown/换配置沿)。回调随后以 CANCELLED 到来,
  /// 槽表即刻清空;取消失败(传输已完/管道已坏)尽力而为不上抛。
  /// 活动时刻归零:取消沿的下一笔读必走空闲回落 sync 一笔(取消态后
  /// 的链路行为未标定,回落笔是实测安全路)。
  private cancelPipeUrbs(): void {
    for (const slot of this.pipeSlots) {
      if (slot.params === null) {
        continue;
      }
      try {
        usb.usbCancelTransfer(slot.params);
      } catch (e) {
        // 尽力而为
      }
    }
    this.pipeSlots = [];
    this.pipeLastActivityMs = 0;
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
  /// 的直接根因,补齐对齐 Android。submit 流水在途 URB 先取消(它们
  /// 手里可能还压着字节,不取消会与冲刷读抢流)。
  private async drainIn(result: MethodResult): Promise<void> {
    const s = this.session;
    if (s === null) {
      result.error('usb_closed', '会话未打开', null);
      return;
    }
    try {
      this.cancelPipeUrbs();
      const drained = await this.drainBulkIn(s, DRAIN_QUIET_MS);
      // 会话轮换守卫:与 bulkRead 同款 —— 旧链路的冲刷结果只释放通道,
      // 不作数(drainBulkIn 里清的 leftover 也随 teardown 重置,无污染)。
      if (this.session !== s) {
        result.error('usb_stale', '会话已轮换,冲刷结果丢弃', null);
        return;
      }
      hlog(`drainIn: ${drained}B`);
      if (drained > 0) {
        Log.i(TAG, `drainIn 吸干 ${drained}B`);
      }
      result.success(drained);
    } catch (e) {
      NativeLog.e('usb', `drainIn 异常:${e}`);
      result.error('usb_error', `drainIn: ${e}`, null);
    }
  }

  /// 程序化拔插(resetUsbDevice,@since 20):相机对「同枚举下的新会话」
  /// 可能整体沉默 —— 进程带会话死亡(装机/杀进程)或深待机后,首笔
  /// 事务 15s 无响应,重试无用,唯 USB 重枚举可治(2026-10-26 真机
  /// 两案,物理拔插均愈)。端口复位强制重枚举 = 等价拔插;复位后设备
  /// 地址可能变化,轮询等归位(至多 5s),返回后 Dart 走常规 open。
  /// 复位借**新连的 pipe**:旧 pipe 经 15s 超时重试后常被 daemon 判死
  /// (14400013 pipe validity 实证),不能直接用;请求权限沿用授权记录。
  private recoveryReset(result: MethodResult): void {
    const s = this.session;
    this.teardownSession();
    if (s === null || typeof usb.resetUsbDevice !== 'function') {
      result.error('usb_unsupported', 'resetUsbDevice 不可用', null);
      return;
    }
    try {
      let ok = false;
      try {
        const pipe = usb.connectDevice(s.device);
        try {
          ok = usb.resetUsbDevice(pipe);
        } finally {
          try {
            usb.closePipe(pipe);
          } catch (e) {
            // 复位后 pipe 已废,关失败忽略
          }
        }
      } catch (e) {
        hlog(`recoveryReset 新 pipe 复位失败: ${e}`);
      }
      hlog(`resetUsbDevice: ${ok}`);
      if (!ok) {
        result.error('usb_error', 'resetUsbDevice false', null);
        return;
      }
    } catch (e) {
      hlog(`resetUsbDevice 异常: ${e}`);
      result.error('usb_error', `resetUsbDevice: ${e}`, null);
      return;
    }
    this.waitReenumerate(result, Date.now() + 5000);
  }

  /// 轮询等复位后的重枚举归位(设备瞬断/重址,枚举可能暂时报错)。
  private async waitReenumerate(result: MethodResult, deadline: number): Promise<void> {
    while (Date.now() < deadline) {
      let found = false;
      try {
        for (const d of usb.getDevices()) {
          if (d.vendorId === NIKON_VENDOR_ID) {
            found = true;
            break;
          }
        }
      } catch (e) {
        // 枚举瞬断忽略,下轮再试
      }
      if (found) {
        hlog('recoveryReset: 设备已重枚举归位');
        result.success(null);
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 250));
    }
    hlog('recoveryReset: 复位后设备未归位');
    result.error('usb_error', 'reset 后设备未归位', null);
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
    // submit 流水线在途 URB 先取消(params 持旧 pipe 引用,不依赖会话)。
    this.cancelPipeUrbs();
    if (s === null) {
      return;
    }
    try {
      usb.releaseInterface(s.pipe, s.iface);
    } catch (e) {
      Log.w(TAG, `releaseInterface: ${e}`);
    }    try {
      usb.closePipe(s.pipe);
    } catch (e) {
      Log.w(TAG, `close: ${e}`);
    }
  }
}
