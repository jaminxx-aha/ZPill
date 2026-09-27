/// 相机连接状态机(TODO.md §二 P1):驱动 UI 的单一事实来源。
///
/// 等价于 TODO.md 中的「连接状态机 + StateFlow」:状态经 Stream 广播,
/// UI 订阅渲染,按钮操作走方法调用。
library;

enum CameraLinkState {
  /// 未连接(初始 / 已清理)。
  disconnected,

  /// 正在检测当前 WiFi 是否为相机热点。
  detecting,

  /// 正在建立双 TCP 通道 + OpenSession。
  connecting,

  /// 会话已建立,可浏览 / 传输。
  connected,

  /// 失败(超时 / InitFail / 心跳超时),错误信息见 [CameraConnection.error]。
  failed,
}

abstract interface class CameraConnection {
  CameraLinkState get state;
  Stream<CameraLinkState> get states;
  String? get error;

  /// 连接:[ip] 为空时先用启发式检测,失败回落 [kDefaultCameraIp];
  /// 需处理超时与错误上报(TODO.md §二 P1)。
  Future<void> connect({String? ip});

  /// 断开清理:关 socket、取消协程、复位状态(TODO.md §二 P1)。
  Future<void> disconnect();
}

/// TODO(P1): 组合 camera_discovery 启发式 + PtpIpSession + ProbeKeepalive,
/// 在 connect() 中编排:检测 WiFi → 双通道 → OpenSession → 启动心跳。
final class CameraConnectionImpl implements CameraConnection {
  @override
  CameraLinkState get state => throw UnimplementedError();

  @override
  Stream<CameraLinkState> get states => throw UnimplementedError();

  @override
  String? get error => throw UnimplementedError();

  @override
  Future<void> connect({String? ip}) => throw UnimplementedError();

  @override
  Future<void> disconnect() => throw UnimplementedError();
}
