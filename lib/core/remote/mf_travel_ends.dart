import '../ptp/ptp_session.dart' show MfDriveOutcome;

/// MF 拉焦端点状态机(纯类,nico `MfDriveResult` 语义,MIT 借思路):
/// 0x9204 是相对量驱动,协议无绝对焦点位置读出 —— 「镜头顶在行程哪一
/// 端」只能靠结果码按**当次请求方向**(1=近/2=远)归因学习:
///
/// - 0xA00C 行程尽头([MfDriveOutcome.endOfTravel]):顶在请求方向的
///   端点 —— 置本向旗、清反向旗(镜头不可能同时顶在两端,nico
///   `_mfNearLimit = near; _mfFarLimit = !near` 同款);
/// - 驱动成功([MfDriveOutcome.complete]):镜头动了,不再顶在任何
///   端点,双清(nico MOVED);
/// - 0xA00E 步进过小([MfDriveOutcome.stepTooSmall])与链路类拒答
///   ([MfDriveOutcome.refused]):镜头未动,端点态不变(nico NO_MOVE)。
///
/// 反向请求([noteDrive])即解锁:请求一经发出,反向端点的旗标作废 ——
/// 镜头正被驱动离开该端(nico 靠「驱动成功双清」事后清,本仓提前到
/// 请求沿,拉焦轮拖动方向反转后首步请求即解锁,不把反向拖动也锁死)。
/// AF 驱动移焦后端点态整体作废([clear],nico clearMfLimits)。
///
/// 旗标是省流量提示而非硬状态:镜头对焦环被人手动转动后旗标可能过期,
/// 但反向请求一步即解锁、再驱动靠机身 0xA00C 重新归因,自愈无损。
class MfTravelEnds {
  MfTravelEnds({this.nearEnd = false, this.farEnd = false});

  /// 近端已到(再向近没有行程)。
  bool nearEnd;

  /// 远端已到(再向远没有行程)。
  bool farEnd;

  /// 任一端点已到:拉焦轮压暗 / 对焦区提示行的判据。
  bool get anyEnd => nearEnd || farEnd;

  /// 一次 0x9204 派出([towardNear] = 请求方向):反向端点旗标作废
  /// (镜头正在离开该端)。
  void noteDrive(bool towardNear) {
    if (towardNear) {
      farEnd = false;
    } else {
      nearEnd = false;
    }
  }

  /// 一次 0x9204 的结果归因([towardNear] = 当次请求方向)。
  void apply({required bool towardNear, required MfDriveOutcome outcome}) {
    switch (outcome) {
      case MfDriveOutcome.endOfTravel:
        // 0xA00C:顶在请求方向的端点 —— 置本向旗、清反向旗。
        nearEnd = towardNear;
        farEnd = !towardNear;
      case MfDriveOutcome.complete:
        // 镜头动了:不再顶在任何端点。
        nearEnd = false;
        farEnd = false;
      case MfDriveOutcome.stepTooSmall:
      case MfDriveOutcome.refused:
        // 0xA00E 镜头未动 / 链路类拒答:端点态不变。
        break;
    }
  }

  /// AF 驱动/外部移焦:端点态整体作废。
  void clear() {
    nearEnd = false;
    farEnd = false;
  }
}
