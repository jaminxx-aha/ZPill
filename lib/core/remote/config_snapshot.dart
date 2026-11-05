/// 拍摄配置快照(机身设置快照/恢复)。
///
/// 快照双轨:①逐属性 —— 遍历 DeviceInfo.devicePropsSupported,逐属性
/// GetDevicePropDesc(类型/当前值/可写性一次拿全);②设定文件 blob ——
/// GetCameraSettingData(0x946D)读卡 1 上的机身设定文件(机身菜单
/// 「保存/载入设定」产物,覆盖逐属性够不到的菜单级设置),两者都存。
/// 恢复 = 有 blob 先 SendCameraSettingData(0x946E,**只写卡不生效**
/// —— 机身菜单载入后生效;失败回落逐属性):逐属性复查可写性与类型
/// 一致后 SetDevicePropValue(直接生效)。
///
/// 写路径受 [PtpSession.kSetPropEnabled] 总闸(2026-10-05 生产已开,
/// 紧急关断时恢复直接 UnsupportedError);快照本身纯读,不受闸。单属性
/// 失败跳过不中断(快照尽力而为,恢复计 failed 继续后面的属性)。
library;

import 'dart:convert' show base64Decode, base64Encode;
import 'dart:typed_data' show Uint8List;

import '../log/app_log.dart';
import '../ptp/device_prop.dart';
import '../ptp/operation_codes.dart';
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
    this.settingsBlobName,
    this.settingsBlob,
  });

  final String model;
  final String deviceVersion;
  final String? serialNumber;
  final DateTime capturedAt;
  final List<ConfigPropSnapshot> props;

  /// 设定文件 blob 轨道(0x946D 产物;null = 快照时无卡/不支持)。
  /// [settingsBlobName] = 0x946D 数据集前 64B 的卡上文件名(回写
  /// 0x946E 时沿用)。
  final String? settingsBlobName;
  final Uint8List? settingsBlob;

  Map<String, Object?> toJson() => {
        'model': model,
        'deviceVersion': deviceVersion,
        if (serialNumber != null) 'serialNumber': serialNumber,
        'capturedAt': capturedAt.toIso8601String(),
        'props': [for (final p in props) p.toJson()],
        if (settingsBlob != null)
          'settingsBlobName': settingsBlobName,
        if (settingsBlob != null) 'settingsBlob': base64Encode(settingsBlob!),
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
        settingsBlobName: json['settingsBlobName'] as String?,
        settingsBlob: _blobFromJson(json['settingsBlob']),
      );

  /// blob 反序列化:base64 损坏/手改文件 → null(回落逐属性轨道)。
  static Uint8List? _blobFromJson(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } on FormatException {
      return null;
    }
  }
}

/// 一次恢复的结果汇总(UI 提示用)。
final class RestoreReport {
  const RestoreReport({
    required this.applied,
    required this.skipped,
    required this.failed,
    this.modeGated = 0,
    this.modelMismatch = false,
    this.blobSaved = false,
    this.verified = 0,
    this.mismatched = 0,
    this.unverified = 0,
  });

  /// 写成功的属性数(blob 轨道成功时为 0 —— 属性未逐个写)。
  final int applied;

  /// 写后读回(0x1015)与写入值一致的属性数。
  final int verified;

  /// 写入返回成功但读回值不一致(已发送未生效;相机可能做了档位
  /// 取整/夹取,不等于写入失败)的属性数。
  final int mismatched;

  /// 写入成功但读回失败或值不可比(0x1015 拒绝/超时/类型不可比)的
  /// 属性数;读回只作诊断,不影响 [applied]/[failed]。
  final int unverified;

  /// 不可写/类型漂移/快照时即只读而跳过的属性数。
  final int skipped;

  /// 相机拒绝(非忙错误等)的属性数。
  final int failed;

  /// 模式门拒绝(0x200F:拨盘/当前模式不适配)而跳过的属性数;
  /// 属预期门,不计入 [failed]。
  final int modeGated;

  /// 当前机身型号与快照机身不一致(提示不拦截)。
  final bool modelMismatch;

  /// 设定文件 blob 轨道成功(0x946E 写卡 1;**经机身菜单载入后才生效**,
  /// UI 提示须如实区分)。
  final bool blobSaved;

  @override
  String toString() {
    // 写后读回是诊断而非第二道成败门:读回不一致/失败只如实提示,
    // 不改写入计数(对齐 NikonCameraControl 的 verified 口径)。
    final readback = applied == 0
        ? ''
        : '(读回一致 $verified 项'
            '${mismatched > 0 ? ',不一致 $mismatched 项(已发送未生效)' : ''}'
            '${unverified > 0 ? ',无法确认 $unverified 项' : ''})';
    final detail = '写入 $applied 项$readback,跳过 $skipped 项'
        '${modeGated > 0 ? ',模式门跳过 $modeGated 项' : ''}'
        ',失败 $failed 项'
        '${modelMismatch ? '(注意:与快照机身型号不一致)' : ''}';
    return blobSaved
        ? '恢复完成:设定文件已写入机身卡(经机身菜单「载入设定」生效);$detail'
        : '恢复完成:$detail';
  }
}

final class CameraConfigSnapshotter {
  const CameraConfigSnapshotter._();

  /// 恢复豁免的时钟属性(0x5011 Date Time):快照存的是拍摄时刻,
  /// 回写旧值会被相机 0x201C(Invalid Device Prop Value)拒;时钟不
  /// 属于可恢复的拍摄配置。
  static const int _propDateTime = 0x5011;

  /// Nikon 用 0x200F(Access Denied 方言)表达拨盘/当前模式不适配;
  /// 恢复时计「模式门跳过」,不按故障。
  static const int _rcModeGate = 0x200F;

  /// 主机会话元数据(SessionInitiatorVersionInfo):不属于拍摄配置;
  /// 写回会按「上一位主机」污染相机会话信息(2026-11-05 真机:快照恢复
  /// 把 Windows MTP 串写回后,iOS/Android 远程录像均 0xA004)。
  static const int _propSessionInitiatorVersionInfo = 0xD406;

  /// 纯照片向属性:视频档恢复时跳过(视频曝光/录制走 0xD1xx 族)。
  static const Set<int> _photoOnlyInVideo = {0x5007, 0x5013, 0x5018};

  /// 抓当前机身的全量设备属性快照。
  ///
  /// 属性清单来自缓存的 GetDeviceInfo(连接时已取);PropDesc 值区缺失
  /// (截断方言)或单属性失败 → 该属性不入快照,整体不失败。属性轨道
  /// 之后追加设定文件 blob(0x946D,无卡/不支持 → null,尽力而为)。
  /// 两轨全空时抛 [FormatException](多半是链路/会话已死,应显式报错)。
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
    String? blobName;
    Uint8List? blob;
    try {
      final s = await session.getCameraSettingData();
      if (s.data.isNotEmpty) {
        blobName = s.name;
        blob = s.data;
      }
    } on Exception {
      // 0x946D 失败(无卡/Store_Not_Available/旧机身):blob 轨道缺席
    }
    if (props.isEmpty && blob == null) {
      throw const FormatException('未读到任何设备属性(链路/会话可能已断)');
    }
    return CameraConfigSnapshot(
      model: info.model,
      deviceVersion: info.deviceVersion,
      serialNumber: info.serialNumber,
      capturedAt: DateTime.now(),
      props: props,
      settingsBlobName: blobName,
      settingsBlob: blob,
    );
  }

  /// 把快照写回相机。
  ///
  /// **默认逐属性直接写**(0x1016,立即生效)。设定文件 blob 轨道改为
  /// 显式 opt-in([writeBlob]):0x946E 只写卡不生效,且真机实证会把
  /// 相机「载入设定」菜单置灰(写回后相机内部“可载入”状态被 reset,
  /// 2026-11-05),故恢复 UI 不再使用它,保留作显式备份/工具路径。
  /// blob 轨道:0x946E 单事务整档写卡 1,成功报告 [RestoreReport.blobSaved];
  /// 遇 0x2019 有界退避、0x201E/0x2003 重开会话,终态失败回落逐属性:
  /// GetDevicePropDesc 复查(可写性以**当下**上报为准,快照时的
  /// writable 只作预过滤;类型漂移跳过)→ SetDevicePropValue → 立即
  /// GetDevicePropValue 写后读回比对([RestoreReport.verified] /
  /// [RestoreReport.mismatched] / [RestoreReport.unverified];读回只
  /// 诊断,不重写、不计失败)。写路径总闸未开时直接抛
  /// UnsupportedError(零流量)。型号不匹配不拦截,报告里提示。
  static Future<RestoreReport> restore(
    PtpSession session,
    CameraConfigSnapshot snapshot, {
    bool videoMode = false,
    bool writeBlob = false,
    Future<void> Function(Duration)? delay,
  }) async {
    if (!PtpSession.kSetPropEnabled) {
      throw UnsupportedError('恢复已被总闸关断(kSetPropEnabled=false,紧急关断)');
    }
    final wait = delay ?? Future<void>.delayed;
    var applied = 0, skipped = 0, modeGated = 0, failed = 0;
    var verified = 0, mismatched = 0, unverified = 0;
    var modelMismatch = false;
    try {
      final info = await session.getDeviceInfo();
      modelMismatch = info.model != snapshot.model;
    } on Exception {
      // 拿不到设备信息:不强拦,型号比对留 false
    }
    final blob = snapshot.settingsBlob;
    // 回写沿用 0x946D 报的卡上文件名;名字缺失(数据集截断/旧档)不
    // 盲写匿名文件到卡,直接走逐属性。
    if (writeBlob &&
        blob != null &&
        blob.isNotEmpty &&
        (snapshot.settingsBlobName ?? '').isNotEmpty) {
      try {
        await _sendRestoredBlob(
            session, snapshot.settingsBlobName ?? '', blob, wait);
        return RestoreReport(
            applied: 0,
            skipped: 0,
            failed: 0,
            modelMismatch: modelMismatch,
            blobSaved: true);
      } on Exception {
        // blob 轨道失败(无卡/拒写/名字不收):回落逐属性
      }
    }
    // 视频档恢复要跳过照片向属性(写进去会卡坏视频门,2026-11-05
    // 真机 0xA004 复现);videoMode 由调用方按当前相机模式传入。
    for (final p in snapshot.props) {
      if (!p.writable) {
        skipped++;
        continue;
      }
      if (p.code == _propDateTime ||
          p.code == _propSessionInitiatorVersionInfo) {
        // 时钟/主机会话元数据:不属于可恢复的拍摄配置。
        skipped++;
        continue;
      }
      if (videoMode && _photoOnlyInVideo.contains(p.code)) {
        // 视频档跳过纯照片向属性(0x5007 F-Number / 0x5013 StillCaptureMode
        // / 0x5018 BurstNumber),避免写坏视频门。
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
        await _writeRestoredProp(
            session,
            PtpDevicePropValue(
                code: p.code, dataType: desc.dataType, value: p.value),
            wait);
        applied++;
        // 0x1016 回 OK 不等于生效:立即 0x1015 读回比对(参考
        // NikonCameraControl 的写后读回口径)。读回只诊断,不重写、
        // 不计失败 —— 相机对枚举/范围做夹取时属于预期差异。
        final match = await _readbackMatches(session, p.code, p.value);
        if (match == null) {
          unverified++;
        } else if (match) {
          verified++;
        } else {
          mismatched++;
          AppLog.w(
            AppLog.system,
            '快照恢复属性 0x${p.code.toRadixString(16)} 已写入但读回不一致'
            '(目标 ${p.value})',
          );
        }
      } on PtpResponseException catch (e) {
        if (e.responseCode == _rcModeGate) {
          // 拨盘/当前模式不适配:预期门,不计故障。
          modeGated++;
          AppLog.i(
            AppLog.system,
            '快照恢复属性 0x${p.code.toRadixString(16)} 模式门跳过(0x200F)',
          );
        } else {
          AppLog.w(
            AppLog.system,
            '快照恢复属性 0x${p.code.toRadixString(16)} 失败: $e',
          );
          failed++;
        }
      } on Exception catch (e) {
        AppLog.w(
          AppLog.system,
          '快照恢复属性 0x${p.code.toRadixString(16)} 失败: $e',
        );
        failed++;
      }
    }
    return RestoreReport(
        applied: applied,
        skipped: skipped,
        failed: failed,
        modeGated: modeGated,
        modelMismatch: modelMismatch,
        verified: verified,
        mismatched: mismatched,
        unverified: unverified);
  }

  static Future<void> _sendRestoredBlob(
    PtpSession session,
    String name,
    Uint8List data,
    Future<void> Function(Duration) delay,
  ) async {
    var busyAttempts = 0;
    var sessionRetried = false;
    while (true) {
      try {
        await session.sendCameraSettingData(name, data);
        return;
      } on PtpResponseException catch (e) {
        if (e.responseCode == PtpResponseCode.deviceBusy && busyAttempts < 2) {
          busyAttempts++;
          await delay(Duration(milliseconds: 200 * busyAttempts));
          continue;
        }
        // 0x201E/0x2003 同为会话账丢(重复 OpenSession / 会话已关);
        // 2026-11-05 B 批真机:CloseSession 后操作回 0x2003。
        if ((e.responseCode == PtpResponseCode.sessionAlreadyOpen ||
                e.responseCode == PtpResponseCode.sessionNotOpen) &&
            !sessionRetried) {
          sessionRetried = true;
          await session.reopen();
          continue;
        }
        rethrow;
      }
    }
  }

  /// 写后读回比对:true=一致,false=不一致,null=读回失败/不可比。
  ///
  /// 0x1015 的响应是裸值,[PtpSession.getDevicePropValue] 按标准类型表
  /// 或长度嗅探解码;这里只比较解码后的整数/字符串,避免把字节宽度
  /// 差异误判成值差异。读回异常一律吞掉并返回 null —— 诊断失败不能
  /// 反向污染恢复流程。
  static Future<bool?> _readbackMatches(
    PtpSession session,
    int code,
    Object? expected,
  ) async {
    try {
      final actual = (await session.getDevicePropValue(code)).value;
      if (expected == null || actual == null) return expected == actual;
      if (expected is int && actual is int) return expected == actual;
      if (expected is String && actual is String) return expected == actual;
      return null; // 解码类型不同:不可比,计入无法确认
    } on Exception catch (e) {
      AppLog.w(
        AppLog.system,
        '快照恢复属性 0x${code.toRadixString(16)} 读回失败: $e',
      );
      return null;
    }
  }

  static Future<void> _writeRestoredProp(
    PtpSession session,
    PtpDevicePropValue value,
    Future<void> Function(Duration) delay,
  ) async {
    var busyAttempts = 0;
    var sessionRetried = false;
    while (true) {
      try {
        await session.setDevicePropValue(value);
        return;
      } on PtpResponseException catch (e) {
        if (e.responseCode == PtpResponseCode.deviceBusy && busyAttempts < 2) {
          busyAttempts++;
          await delay(Duration(milliseconds: 200 * busyAttempts));
          continue;
        }
        // 0x201E/0x2003 同为会话账丢(重复 OpenSession / 会话已关);
        // 2026-11-05 B 批真机:CloseSession 后操作回 0x2003。
        if ((e.responseCode == PtpResponseCode.sessionAlreadyOpen ||
                e.responseCode == PtpResponseCode.sessionNotOpen) &&
            !sessionRetried) {
          sessionRetried = true;
          await session.reopen();
          continue;
        }
        rethrow;
      }
    }
  }
}
