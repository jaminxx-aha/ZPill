/// 相机连接状态机(TODO.md §二 P1):驱动 UI 的单一事实来源。
///
/// 等价于 TODO.md 中的「连接状态机 + StateFlow」:状态经 Stream 广播,
/// UI 订阅渲染,按钮操作走方法调用。
library;

import 'dart:async';

import '../../platform/usb/usb_host.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';

enum CameraLinkState {
  /// 未连接(初始 / 已清理)。
  disconnected,

  /// 正在检测当前 WiFi 是否为相机热点。
  detecting,

  /// 正在建立链路 + OpenSession。
  connecting,

  /// 会话已建立,可浏览 / 传输。
  connected,

  /// 失败(超时 / 无设备 / 会话拒绝),错误信息见 [CameraConnection.error]。
  failed,
}

abstract interface class CameraConnection {
  CameraLinkState get state;
  Stream<CameraLinkState> get states;
  String? get error;

  /// 已连接设备的展示名(如 "NIKON ZF";来自 GetDeviceInfo);
  /// 未连接为 null。
  String? get deviceName;

  /// 连接:USB 主线下 [ip] 忽略(PTP-IP 无线线接入后再用);
  /// 需处理超时与错误上报(TODO.md §二 P1)。
  Future<void> connect({String? ip});

  /// 断开清理:关会话、释放 USB 接口、复位状态(TODO.md §二 P1)。
  Future<void> disconnect();
}

/// USB 主线实现(P0 闭环):
/// listCameras → open(独占 STI 接口)→ GetDeviceInfo → OpenSession
/// (0x201E 自动恢复在 [PtpSession.open] 内)→ connected。
///
/// 2026-10-01 补两道防线:
/// - GetDeviceInfo 后检查受限画像(op 表缺 GetObject → 连接期拦截,
///   给出「关机重启」对策,不再让用户面对满屏 0x200F);
/// - 订阅 [UsbHostChannel.breakages]:相机中途拔出/链路死亡时
///   connected 即刻转 failed(看门狗检测,详见 WatchdogUsbHostChannel)。
///
/// 依赖注入:[usb] 是 platform 侧的通道抽象(仅接口依赖,native 契约与
/// 实现同文件,测试注入 Fake);[session] 必须架在同一条字节管道之上
/// (AppServices 组装保证)。detecting 态属 WiFi 启发式线,本实现跳过。
final class CameraConnectionImpl implements CameraConnection {
  CameraConnectionImpl({required UsbHostChannel usb, required PtpSession session})
      : _usb = usb,
        _session = session {
    // 断链事件只在 connected 态生效;connecting 态的失败由 connect()
    // 自己的 catch 上报,failed/disconnected 已无会话可清。
    _usb.breakages.listen(_onLinkBreakage);
  }

  final UsbHostChannel _usb;
  final PtpSession _session;

  final StreamController<CameraLinkState> _statesCtrl =
      StreamController<CameraLinkState>.broadcast();

  CameraLinkState _state = CameraLinkState.disconnected;
  String? _error;
  String? _deviceName;

  @override
  CameraLinkState get state => _state;

  @override
  Stream<CameraLinkState> get states => _statesCtrl.stream;

  @override
  String? get error => _error;

  @override
  String? get deviceName => _deviceName;

  @override
  Future<void> connect({String? ip}) async {
    if (_state == CameraLinkState.connected ||
        _state == CameraLinkState.connecting) {
      return;
    }
    _transition(CameraLinkState.connecting);
    try {
      final cameras = await _usb.listCameras();
      if (cameras.isEmpty) {
        _error = '未发现尼康相机:请插好 USB 数据线并解锁相机后重试';
        _transition(CameraLinkState.failed);
        return;
      }
      await _usb.open(cameras.first);
      // GetDeviceInfo 是 OpenSession 之前唯一允许的操作,顺带拿到型号名。
      // force:相机重启后 op 表可能变化(受限画像 ⇄ 全量),不能吃上次
      // 连接的缓存。
      final info = await _session.getDeviceInfo(force: true);
      if (!info.supportsOperation(PtpOperationCode.getObject)) {
        // 受限画像(2026-10-01 真机:op 表只剩元数据/属性/事件,
        // GetObject/GetThumb 等数据操作全 0x200F;触发器未明,自行翻回)。
        // 与其让缩略图/下载逐个莫名失败,不如连接期就拦下并给出对策。
        _error = '相机处于受限连接状态(数据操作被禁用):'
            '请关闭相机电源,重新开机后再连接';
        _transition(CameraLinkState.failed);
        await _teardown();
        return;
      }
      await _session.open();
      _deviceName = info.model;
      _error = null;
      _transition(CameraLinkState.connected);
    } on Exception catch (e) {
      _error = '$e';
      _transition(CameraLinkState.failed);
      await _teardown();
    }
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
    _error = null;
    _transition(CameraLinkState.disconnected);
  }

  /// 会话与设备级清理(尽力而为:链路已死时 CloseSession 必然失败,
  /// 不能让它吞掉后面的 usb.close;Error 也吞 —— 会话层关闭态抛
  /// StateError,属 Error 非 Exception)。
  Future<void> _teardown() async {
    _deviceName = null;
    try {
      await _session.close();
    } on Object {
      // 链路已断:会话层的本地状态已复位,足够
    }
    try {
      await _usb.close();
    } on Object {
      // 同上
    }
  }

  /// 断链回调:connected → failed(带原因),并尽力清理。
  void _onLinkBreakage(String reason) {
    if (_state != CameraLinkState.connected) return;
    _error = reason;
    _transition(CameraLinkState.failed);
    // 看门狗已毒化管道,CloseSession 秒回失败,由 _teardown 吞掉。
    unawaited(_teardown());
  }

  void _transition(CameraLinkState s) {
    _state = s;
    _statesCtrl.add(s);
  }
}
