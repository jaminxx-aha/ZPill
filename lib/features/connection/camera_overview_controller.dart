/// 相机信息总览控制器(相机页已连接视图的数据源)。
///
/// 全部来自相机实时属性,不拍照(能力门禁:相机声明表说了不支持的码
/// 不发,响应零浪费):
/// - 机身:GetDeviceInfo(型号/固件/序列号,会话内缓存);
/// - 电池/焦距/光圈:标准属性码 0x5001/0x5008/0x5007,
///   仅当 [PtpDeviceInfo.devicePropsSupported] 在册才读(裸值 0x1015);
/// - 镜头规格:0xD0E3-E6 焦距上下限/两端最大光圈 + 0xD0E0 镜头 ID
///   (只读实时属性,连接沿直读;Zf 实证不在声明表但应答,2026-10-12
///   USB 探针)—— 不拍照即知挂机镜头,ID 命中 [kLensIdNames] 直接出
///   营销名全称,未收录退规格描述(如「40mm ƒ/2」)。
/// - 实时追平(0x4006 事件,不拍照):焦距/光圈随拨轮、变焦、换镜
///   即时刷新(声明表门禁);规格/ID 码不推事件(2026-10-12 探针),
///   0x5008 沿补读 ID 对比 = 换镜精确判(同区间换镜焦距不挪也抓到)
///   → 规格五连读 + 光圈对表;出区间启发式兜底。
///
/// 拒绝/失败均静默降级为该字段保持空(界面回 '--'),不报错 —— 信息
/// 卡是锦上添花,不拦使用。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/camera/camera_connection.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';

/// 挂机镜头规格(0xD0E3-E6 拼装;连接沿实时读,不拍照即知)。
final class LensSpec {
  const LensSpec({
    required this.focalMinMm,
    required this.focalMaxMm,
    required this.maxApertureWide,
    required this.maxApertureTele,
  });

  /// 焦距下限/上限 mm(0xD0E3/0xD0E4 ÷100,0.01mm 定点族)。
  final double focalMinMm;
  final double focalMaxMm;

  /// 广角端/远摄端最大光圈(0xD0E5/0xD0E6,ƒ×100 与 0x5007 同标度)。
  final int maxApertureWide;
  final int maxApertureTele;

  /// 实测焦距落点检验:换镜哨里焦距挪出规格区间 = 启发式换镜信号
  /// (ID 读不到时的兜底判)。
  bool containsFocal(double mm) => mm >= focalMinMm && mm <= focalMaxMm;

  /// 规格描述(LensID 未收录进 [kLensIdNames] 时的镜头行退路):
  /// 定焦「40mm ƒ/2」,变焦「24-200mm ƒ/2.8-6.3」。
  String get description {
    String trim(num v) {
      final r = (v * 100).round() / 100;
      return r == r.roundToDouble() ? r.round().toString() : '$r';
    }

    // 光圈字段是 ƒ×100 定点(200 = ƒ/2),先回 ƒ 值再截尾零。
    String trimAperture(int v) => trim(v / 100);

    final focal = focalMinMm == focalMaxMm
        ? '${trim(focalMinMm)}mm'
        : '${trim(focalMinMm)}-${trim(focalMaxMm)}mm';
    final aperture = maxApertureWide == maxApertureTele
        ? 'ƒ/${trimAperture(maxApertureWide)}'
        : 'ƒ/${trimAperture(maxApertureWide)}-${trimAperture(maxApertureTele)}';
    return '$focal $aperture';
  }
}

/// Z 头 LensID(0xD0E0)→ 营销名。官方 Zf USB MTP 指令书定案:协议
/// 无镜头名属性,LensID 每镜唯一(未挂固定 0)—— 映射命中即可不拍照
/// 出全名(含 SE 等后缀,规格描述做不到)。表值 2026-10-12 USB 探针
/// 实测锚点,新镜头换挂探一把即扩表;未收录的 ID 走规格描述路。
const Map<int, String> kLensIdNames = {
  25: 'NIKKOR Z 40mm f/2 SE',
  31: 'NIKKOR Z 24-120mm f/4 S',
};

/// 0x1015 裸值安全取整:方言偏离转长度嗅探后可能回 string/uint64
/// (见 PtpDevicePropValue.parse),`as int?` 硬转型抛 TypeError 逃
/// `on Exception` 收口网 —— 整链静默中断、notify 不再发;此处退
/// null = 该字段缺省,链照走。
int? _asInt(Object? v) => v is int ? v : null;

final class CameraOverviewController extends ChangeNotifier {
  CameraOverviewController({
    required this.session,
    required this.connection,
    this.propResyncDebounce = const Duration(milliseconds: 500),
    this.connectRefreshDelay = Duration.zero,
  }) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        _refreshWhenDue();
      } else if (s == CameraLinkState.reconnecting) {
        // 自动重连期:门闩挡迟到的读数,数据冻结不清 —— 重连成功沿
        // refresh() 照旧重载。
        _linkUp = false;
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _invalidate();
      }
    });
    // 属性事件(0x4006):焦距/光圈随拨轮、变焦、换镜即时追平。
    _eventsSub = session.events.listen(_onSessionEvent);
  }

  final PtpSession session;
  final CameraConnection connection;

  /// 属性事件(0x4006)追平的去抖窗:拨轮串/变焦步进收敛为一次读值。
  /// 可注入(测试零等待)。
  final Duration propResyncDebounce;

  /// 连接沿刷新让路(生产装配传 2s,测试默认零等待):概览整链 8 事务
  /// 与起景链在会话串行锁上轮转,曾把 0x9201 压到十几事务深 —— 拍摄页
  /// 「取景未开启」卡好几秒(2026-10-16 真机定案)。让起景链先独跑,
  /// 首帧上屏后概览再上路。
  final Duration connectRefreshDelay;

  void _refreshWhenDue() {
    if (connectRefreshDelay == Duration.zero) {
      unawaited(refresh());
      return;
    }
    unawaited(Future<void>.delayed(connectRefreshDelay, () {
      // 延迟窗里沿翻篇(断开/重连)不追;重连沿有自己的新定时。
      if (connection.state == CameraLinkState.connected) {
        unawaited(refresh());
      }
    }));
  }

  /// 机身信息(GetDeviceInfo);null = 未连接/未读到。
  PtpDeviceInfo? deviceInfo;

  /// 电池余量(%);null = 相机不报或读取失败(界面行回 '--' 占位)。
  int? batteryPercent;

  /// 当前焦距(mm);null 同上。
  double? focalLengthMm;

  /// 当前光圈 ×100(280 = ƒ/2.8;ISO 15740 定点);null 同上。
  int? fNumber;

  /// 挂机镜头规格(0xD0E3-E6);null = 拒答/异构机身无此路/未挂镜。
  LensSpec? lensSpec;

  /// 挂机镜头 ID(0xD0E0,官方指令书 6.5.10.4);null = 拒答/未挂。
  /// [kLensIdNames] 命中即镜头行出全名。
  int? lensId;

  /// 最近一次确认的镜头 ID(0 = 未知):换镜精确判的基准 —— 新读 ID
  /// 与已知不同即换镜(同区间换镜焦距不挪,出区间启发式抓不到)。
  int _knownLensId = 0;

  /// 镜头行展示值:ID 映射命中即挂机镜头营销名全称(不拍照);未收录
  /// ID 退规格描述(焦距 + 两端最大光圈,如「40mm ƒ/2」)。
  String? get lensDisplay => kLensIdNames[lensId] ?? lensSpec?.description;

  bool _linkUp = false;
  bool _refreshing = false;
  bool _propReading = false;
  final Set<int> _pendingPropReads = <int>{};
  Timer? _propTimer;

  StreamSubscription<CameraLinkState>? _statesSub;
  StreamSubscription<PtpEvent>? _eventsSub;

  /// 连接成功 / 手动刷新:机身 + 属性(能力门禁)。
  ///
  /// 渐进式刷新(2026-10-16 真机反馈「连接后电池/镜头卡几秒才刷出」
  /// 修):各数据点赋值沿即 notify,不等整链 —— 全链串行 8 事务
  /// (Wi-Fi 每事务一次往返),链尾一次 notify 曾把电池、镜头整卡压到
  /// 全链跑完才一起亮。
  Future<void> refresh() async {
    if (_refreshing || !_linkUp) return;
    _refreshing = true;
    try {
      final info = await session.getDeviceInfo();
      if (!_linkUp) return;
      deviceInfo = info;
      notifyListeners(); // 机身组(型号/固件/序列号)先亮
      for (final code in const [
        PtpDevicePropCode.batteryLevel,
        PtpDevicePropCode.focalLength,
        PtpDevicePropCode.fNumber,
      ]) {
        if (!info.devicePropsSupported.contains(code)) continue;
        try {
          final v = await session.getDevicePropValue(code);
          if (!_linkUp) return;
          final value = _asInt(v.value);
          if (value == null) continue;
          switch (code) {
            case PtpDevicePropCode.batteryLevel:
              batteryPercent = value;
            case PtpDevicePropCode.focalLength:
              // 0x5008 裸值单位 0.01mm(ISO 15740/libgphoto2 ÷100,
              // 与 FNumber ×100 同族定点;40mm 镜头回 4000)。
              focalLengthMm = value / 100;
            case PtpDevicePropCode.fNumber:
              fNumber = value;
          }
          notifyListeners(); // 单点亮:电池第 1 事务后即见,不等规格五连读
        } on Exception {
          // 单属性拒答/失败:该行保持缺省,不拖垮整卡
        }
      }
      await _readLensSpec();
      notifyListeners(); // 镜头行(ID/规格)收尾亮
    } on Exception {
      // GetDeviceInfo 失败 = 链路问题,状态机会收口;信息卡保持已有点
    } finally {
      _refreshing = false;
    }
  }

  /// 事件沿:属性码走实时追平(不拍照)。
  void _onSessionEvent(PtpEvent event) {
    if (!_linkUp) return; // 断连后迟到事件一律丢弃
    // 属性事件(0x4006):焦距/光圈随拨轮、变焦、换镜即时追平。
    if (event.code == PtpEventCode.devicePropChanged) {
      if (event.params.isNotEmpty) _onPropChanged(event.params.first);
    }
  }

  /// 属性追平(0x4006):只理焦距/光圈两码(信息卡两行的实时源;
  /// 2026-10-12 探针:拨轮推 0x5007/0x500D、变焦与换镜推 0x5008,
  /// 规格码 0xD0E3-E6 不推事件)。其余码零动作。
  void _onPropChanged(int code) {
    if (code != PtpDevicePropCode.fNumber &&
        code != PtpDevicePropCode.focalLength) {
      return;
    }
    final info = deviceInfo;
    if (info == null || !info.devicePropsSupported.contains(code)) {
      return; // 能力门禁:声明表外的码不发(refresh 就绪前同此)
    }
    _pendingPropReads.add(code);
    _propTimer?.cancel();
    _propTimer = Timer(propResyncDebounce, _readLiveProps);
  }

  Future<void> _readLiveProps() async {
    if (_propReading || !_linkUp) return;
    _propReading = true;
    try {
      while (_linkUp && _pendingPropReads.isNotEmpty) {
        final codes = _pendingPropReads.toList();
        _pendingPropReads.clear();
        var focalMoved = false;
        for (final code in codes) {
          if (!_linkUp) return;
          try {
            final v = await session.getDevicePropValue(code);
            if (!_linkUp) return;
            final value = _asInt(v.value);
            if (value == null) continue;
            if (code == PtpDevicePropCode.fNumber) {
              fNumber = value;
            } else {
              focalLengthMm = value / 100;
              focalMoved = true;
            }
          } on Exception {
            // 单次读失败:静默,下个事件再来
          }
        }
        // 换镜信号(0xD0E0 不推事件,借 0x5008 沿补读一次 ID):新 ID
        // 与已知不同 = 换镜实锤 —— 同区间换镜(如 24-120→24-70 停在
        // 24mm)焦距不挪,出区间启发式抓不到,ID 对比杀掉这个盲区;
        // ID 拒答/首读(已知 0)退回出区间启发式。规格码不推事件,规格
        // 刷新只能由这条信号驱动;区间内变焦零重读(只多一发 ID 读)。
        if (focalMoved) {
          var idChanged = false;
          try {
            final v =
                await session.getDevicePropValue(PtpDevicePropCode.lensId);
            if (!_linkUp) return;
            final raw = _asInt(v.value);
            if (raw != null && raw != 0) {
              idChanged = _knownLensId != 0 && raw != _knownLensId;
            }
          } on Exception {
            // ID 读失败:退回出区间启发式
          }
          final spec = lensSpec;
          final focal = focalLengthMm;
          final outOfRange =
              spec == null || focal == null || !spec.containsFocal(focal);
          if (idChanged || outOfRange) {
            await _readLensSpec();
            if (!_linkUp) return;
            if (deviceInfo?.devicePropsSupported
                    .contains(PtpDevicePropCode.fNumber) ??
                false) {
              try {
                final v = await session
                    .getDevicePropValue(PtpDevicePropCode.fNumber);
                if (!_linkUp) return;
                final value = _asInt(v.value);
                if (value != null) {
                  fNumber = value;
                }
              } on Exception {
                // 顺带读失败:下个 0x5007 事件再对
              }
            }
          }
        }
        notifyListeners();
      }
    } finally {
      _propReading = false;
    }
  }

  /// 挂机镜头规格(0xD0E3-E6)+ 镜头 ID(0xD0E0 打头):Zf 实证**不在
  /// devicePropsSupported 声明表但 0x1015 应答**(2026-10-12 USB 探针;
  /// 40 SE 回 25/4000/4000/200/200 = ID 25,40-40mm ƒ/2-ƒ/2)—— 声明表
  /// 门禁在此不适用,直读。ID = 0 即未挂镜,规格值官方明说 "not fixed"
  /// 不采(ID 拒答则规格照走,兼容只有规格码的机身);四码任一拒答即
  /// 放弃(旧机型/异构机身静默无规格)。
  Future<void> _readLensSpec() async {
    var idAnswered = false;
    try {
      final v = await session.getDevicePropValue(PtpDevicePropCode.lensId);
      if (!_linkUp) return;
      final raw = _asInt(v.value);
      if (raw != null) {
        idAnswered = true;
        lensId = raw == 0 ? null : raw;
      }
    } on Exception {
      // ID 拒答/链路异常:ID 路放弃,规格路照走(宁缺勿错只针对规格)
    }
    if (idAnswered && lensId == null) {
      lensSpec = null;
      _knownLensId = 0;
      return; // 未挂镜:规格值不固定,不读
    }
    final values = <int, int>{};
    for (final code in const [
      PtpDevicePropCode.lensFocalLengthMin,
      PtpDevicePropCode.lensFocalLengthMax,
      PtpDevicePropCode.lensMaxApertureWide,
      PtpDevicePropCode.lensMaxApertureTele,
    ]) {
      try {
        final v = await session.getDevicePropValue(code);
        if (!_linkUp) return;
        final raw = _asInt(v.value);
        if (raw == null) return;
        values[code] = raw;
      } on Exception {
        return; // 拒答/链路异常:规格路放弃,宁缺勿错
      }
    }
    lensSpec = LensSpec(
      focalMinMm: values[PtpDevicePropCode.lensFocalLengthMin]! / 100,
      focalMaxMm: values[PtpDevicePropCode.lensFocalLengthMax]! / 100,
      maxApertureWide: values[PtpDevicePropCode.lensMaxApertureWide]!,
      maxApertureTele: values[PtpDevicePropCode.lensMaxApertureTele]!,
    );
    if (lensId != null) _knownLensId = lensId!;
  }

  /// 断连/失败:清态(迟到的属性值被门闩挡住)。
  void _invalidate() {
    _linkUp = false;
    deviceInfo = null;
    batteryPercent = null;
    focalLengthMm = null;
    fNumber = null;
    lensSpec = null;
    lensId = null;
    _knownLensId = 0;
    _propTimer?.cancel();
    _pendingPropReads.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel() ?? Future.value());
    unawaited(_eventsSub?.cancel() ?? Future.value());
    _propTimer?.cancel();
    super.dispose();
  }
}
