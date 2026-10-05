/// 拍摄配置快照(TODO §三「菜单预设:机身设置快照/恢复」)。
///
/// 快照 = 遍历 DeviceInfo.devicePropsSupported,逐属性 GetDevicePropDesc
/// (类型/当前值/可写性一次拿全)→ 命名 JSON 落盘([ConfigSnapshotStore]);
/// 恢复 = 逐属性复查可写性与类型一致后 SetDevicePropValue。
///
/// 写路径受 [PtpSession.kSetPropEnabled] 总闸(真机核对前恒关,恢复
/// 直接 UnsupportedError);快照本身纯读,不受闸。单属性失败跳过不
/// 中断(快照尽力而为,恢复计 failed 继续后面的属性)。
library;

import '../ptp/device_prop.dart';
import '../ptp/ptp_session.dart';

/// 快照里的单个设备属性。
final class ConfigPropSnapshot {
  const ConfigPropSnapshot({
    required this.code,
    required this.type,
    required this.value,
    required this.writable,
  });

  /// 属性码(PtpDevicePropCode / 厂商扩展)。
  final int code;

  /// [PtpDataType.name](恢复时按名还原编码宽度)。
  final String type;

  /// 快照值(int / String / null)。
  final Object? value;

  /// 快照时刻相机上报的 getSet(恢复时的预过滤参考)。
  final bool writable;

  Map<String, Object?> toJson() => {
        'code': code,
        'type': type,
        'value': value,
        'writable': writable,
      };

  static ConfigPropSnapshot fromJson(Map<String, Object?> json) =>
      ConfigPropSnapshot(
        code: (json['code'] as num).toInt(),
        type: json['type'] as String,
        // JSON 数字可能解码为 double(手改文件),统一收窄回 int
        value: json['value'] is num ? (json['value'] as num).toInt() : json['value'],
        writable: json['writable'] == true,
      );
}

final class CameraConfigSnapshot {
  const CameraConfigSnapshot({
    required this.model,
    required this.deviceVersion,
    this.serialNumber,
    required this.capturedAt,
    required this.props,
  });

  final String model;
  final String deviceVersion;
  final String? serialNumber;
  final DateTime capturedAt;
  final List<ConfigPropSnapshot> props;

  Map<String, Object?> toJson() => {
        'model': model,
        'deviceVersion': deviceVersion,
        if (serialNumber != null) 'serialNumber': serialNumber,
        'capturedAt': capturedAt.toIso8601String(),
        'props': [for (final p in props) p.toJson()],
      };

  static CameraConfigSnapshot fromJson(Map<String, Object?> json) =>
      CameraConfigSnapshot(
        model: json['model'] as String? ?? '',
        deviceVersion: json['deviceVersion'] as String? ?? '',
        serialNumber: json['serialNumber'] as String?,
        capturedAt: DateTime.tryParse(json['capturedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        props: [
          for (final p in (json['props'] as List<Object?>? ?? const []))
            if (p is Map<String, Object?>) ConfigPropSnapshot.fromJson(p),
        ],
      );
}

/// 一次恢复的结果汇总(UI 提示用)。
final class RestoreReport {
  const RestoreReport({
    required this.applied,
    required this.skipped,
    required this.failed,
    this.modelMismatch = false,
  });

  /// 写成功的属性数。
  final int applied;

  /// 不可写/类型漂移/快照时即只读而跳过的属性数。
  final int skipped;

  /// 相机拒绝(非忙错误等)的属性数。
  final int failed;

  /// 当前机身型号与快照机身不一致(提示不拦截)。
  final bool modelMismatch;

  @override
  String toString() => '恢复完成:写入 $applied 项,跳过 $skipped 项,'
      '失败 $failed 项${modelMismatch ? '(注意:与快照机身型号不一致)' : ''}';
}

final class CameraConfigSnapshotter {
  const CameraConfigSnapshotter._();

  /// 抓当前机身的全量设备属性快照。
  ///
  /// 属性清单来自缓存的 GetDeviceInfo(连接时已取);PropDesc 值区缺失
  /// (截断方言)或单属性失败 → 该属性不入快照,整体不失败。全部属性
  /// 都拿不到时抛 [FormatException](多半是链路/会话已死,应显式报错)。
  static Future<CameraConfigSnapshot> capture(PtpSession session) async {
    final info = await session.getDeviceInfo();
    final props = <ConfigPropSnapshot>[];
    for (final code in info.devicePropsSupported) {
      try {
        final desc = await session.getDevicePropDesc(code);
        if (desc.currentValue == null) continue; // 值不可读:不入快照
        props.add(ConfigPropSnapshot(
          code: desc.code,
          type: desc.dataType.name,
          value: desc.currentValue,
          writable: desc.getSet,
        ));
      } on Exception {
        // 单属性失败:跳过(尽力而为)
      }
    }
    if (props.isEmpty) {
      throw const FormatException('未读到任何设备属性(链路/会话可能已断)');
    }
    return CameraConfigSnapshot(
      model: info.model,
      deviceVersion: info.deviceVersion,
      serialNumber: info.serialNumber,
      capturedAt: DateTime.now(),
      props: props,
    );
  }

  /// 把快照写回相机。
  ///
  /// 逐属性:GetDevicePropDesc 复查(可写性以**当下**上报为准,快照时的
  /// writable 只作预过滤;类型漂移跳过)→ SetDevicePropValue。写路径
  /// 总闸未开时直接抛 UnsupportedError(零流量)。型号不匹配不拦截,
  /// 报告里提示。
  static Future<RestoreReport> restore(
      PtpSession session, CameraConfigSnapshot snapshot) async {
    if (!PtpSession.kSetPropEnabled) {
      throw UnsupportedError('恢复未启用:待真机核对可写域后翻开 kSetPropEnabled');
    }
    var applied = 0, skipped = 0, failed = 0;
    var modelMismatch = false;
    try {
      final info = await session.getDeviceInfo();
      modelMismatch = info.model != snapshot.model;
    } on Exception {
      // 拿不到设备信息:不强拦,型号比对留 false
    }
    for (final p in snapshot.props) {
      if (!p.writable) {
        skipped++;
        continue;
      }
      try {
        final desc = await session.getDevicePropDesc(p.code);
        if (!desc.getSet) {
          skipped++; // 快照时可写,当下只读(模式拨盘变了等)
          continue;
        }
        final snapshotType = PtpDataType.values
            .where((t) => t.name == p.type)
            .firstOrNull;
        if (snapshotType == null || desc.dataType != snapshotType) {
          skipped++; // 类型漂移:值的语义不可比,宁跳不错
          continue;
        }
        await session.setDevicePropValue(
            PtpDevicePropValue(code: p.code, dataType: desc.dataType, value: p.value));
        applied++;
      } on Exception {
        failed++;
      }
    }
    return RestoreReport(
        applied: applied, skipped: skipped, failed: failed, modelMismatch: modelMismatch);
  }
}
