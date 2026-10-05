/// 相机信息总览控制器(相机页已连接视图的数据源)。
///
/// 三路信息,全部能力门禁(相机声明表说了不支持的码不发,响应零浪费):
/// - 机身:GetDeviceInfo(型号/固件/序列号,会话内缓存);
/// - 电池/焦距/光圈:标准属性码 0x5001/0x5008/0x5007,
///   仅当 [PtpDeviceInfo.devicePropsSupported] 在册才读(裸值 0x1015);
/// - 镜头型号:最近一张 JPG 的 EXIF LensModel —— GetPartialObject
///   (0x101B,标准码)只取头部 64KB(EXIF APP1 紧跟 SOI,足够),
///   解析复用水印管线的 [readJpegExif];属性路径缺读时 EXIF 的
///   焦距/光圈顺带兜底。触发时机 = 仓库渐进发布首个含 JPG 的块
///   (句柄倒序,最新照片先到),不等全量枚举。
///
/// 真机核对注:0x5001/0x5008/0x101B 在 Zf 的实际应答未验,拒绝/失败
/// 均静默降级为该行不显示,不报错 —— 信息卡是锦上添花,不拦使用。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/object_repository.dart';
import '../../core/browser/photo_group.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/media/watermark.dart' show exifCardDataOf, readJpegExif;
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';

final class CameraOverviewController extends ChangeNotifier {
  CameraOverviewController({
    required this.session,
    required this.connection,
    this.repository,
  }) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        unawaited(refresh());
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _invalidate();
      }
    });
    // 仓库渐进块:首个含 JPG 的块一到就读镜头(最新照片低延迟亮相,
    // 不等全量枚举完成)。
    _updatesSub = repository?.updates.listen(_onRepoUpdate);
  }

  final PtpSession session;
  final CameraConnection connection;
  final ObjectRepository? repository;

  /// 机身信息(GetDeviceInfo);null = 未连接/未读到。
  PtpDeviceInfo? deviceInfo;

  /// 电池余量(%);null = 相机不报或读取失败(该行不显示)。
  int? batteryPercent;

  /// 当前焦距(mm);null 同上。EXIF 兜底时是「最近一张」的焦距。
  int? focalLengthMm;

  /// 当前光圈 ×10(28 = ƒ/2.8);null 同上。
  int? fNumber;

  /// 镜头型号(最近一张 JPG 的 EXIF LensModel);null = 未知。
  String? lens;

  bool _linkUp = false;
  bool _refreshing = false;
  bool _lensReadDone = false;

  StreamSubscription<CameraLinkState>? _statesSub;
  StreamSubscription<AlbumsUpdate>? _updatesSub;

  /// 连接成功 / 手动刷新:机身 + 属性(能力门禁)。
  Future<void> refresh() async {
    if (_refreshing || !_linkUp) return;
    _refreshing = true;
    try {
      final info = await session.getDeviceInfo();
      if (!_linkUp) return;
      deviceInfo = info;
      for (final code in const [
        PtpDevicePropCode.batteryLevel,
        PtpDevicePropCode.focalLength,
        PtpDevicePropCode.fNumber,
      ]) {
        if (!info.devicePropsSupported.contains(code)) continue;
        try {
          final v = await session.getDevicePropValue(code);
          if (!_linkUp) return;
          final value = v.value as int?;
          if (value == null) continue;
          switch (code) {
            case PtpDevicePropCode.batteryLevel:
              batteryPercent = value;
            case PtpDevicePropCode.focalLength:
              focalLengthMm = value;
            case PtpDevicePropCode.fNumber:
              fNumber = value;
          }
        } on Exception {
          // 单属性拒答/失败:该行保持缺省,不拖垮整卡
        }
      }
      notifyListeners();
    } on Exception {
      // GetDeviceInfo 失败 = 链路问题,状态机会收口;信息卡保持已有点
    } finally {
      _refreshing = false;
    }
  }

  void _onRepoUpdate(AlbumsUpdate update) {
    if (!_linkUp || _lensReadDone) return;
    final albums = update.albums;
    if (albums.isEmpty) return;
    // 汇总相册恒在首位(items 新的在前):跳过视频/纯 RAW 组取首个
    // 带 JPG 的;本块没有就等下一块(块内句柄倒序,新照片先到)。
    for (final group in albums.first.items) {
      if (group.jpg != null) {
        unawaited(_readLens(group));
        return;
      }
    }
  }

  /// 镜头型号:最近一张 JPG 头部 64KB → EXIF LensModel。
  /// 无论成败,一次连接只试一次(换镜头不追新,断连重连才重读)。
  Future<void> _readLens(PhotoGroup newest) async {
    _lensReadDone = true;
    final info = deviceInfo;
    // 能力门禁:0x101B 不在册不发(Zf 应答待真机核对,拒答也不报错)。
    if (info == null ||
        !info.supportsOperation(PtpOperationCode.getPartialObject)) {
      return;
    }
    final jpg = newest.jpg;
    if (jpg == null) return;
    try {
      final head = await session.getPartialObject(jpg.handle, 0, 64 * 1024);
      if (!_linkUp) return;
      final exif = readJpegExif(head);
      if (exif == null) return;
      final card = exifCardDataOf(exif);
      lens = card.lens;
      // 属性路径缺读时 EXIF 兜底(标注语义变为「最近一张」)。
      focalLengthMm ??= card.focalLengthMm?.round();
      fNumber ??= card.fNumber == null ? null : (card.fNumber! * 10).round();
      notifyListeners();
    } on Exception {
      // 部分读被拒/链路异常:镜头行留空
    }
  }

  /// 断连/失败:清态(迟到的仓库块/属性值被门闩挡住)。
  void _invalidate() {
    _linkUp = false;
    deviceInfo = null;
    batteryPercent = null;
    focalLengthMm = null;
    fNumber = null;
    lens = null;
    _lensReadDone = false;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel() ?? Future.value());
    unawaited(_updatesSub?.cancel() ?? Future.value());
    super.dispose();
  }
}
