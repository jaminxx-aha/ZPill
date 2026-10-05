/// 速传服务(TODO.md §二 P1):ObjectAdded 事件驱动自动下载。
///
/// 相机侧新对象落地 → ObjectAdded(0x4002,SDRAM 拍摄走尼康 0xC101)
/// 事件携带最终 handle(2026-09-27 Zf 真机实证,可直接 GetObjectInfo/
/// GetObject)→ 按设置开关与格式过滤 → [TransferEngine] 入队(gallery
/// 目的地,两段式导入与其他下载共用同一队列与重试)。
///
/// 事件流经 PtpLinkRouter 广播:USB interrupt / 无线 evt 通道同构,
/// 断连后无事件、订阅常驻无害;单张失败只丢当张(onSkip 诊断),
/// 不影响后续照片。
library;

import 'dart:async';

import '../browser/object_entry.dart';
import '../browser/object_repository.dart';
import '../browser/photo_group.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';
import '../ptpip/object_format.dart';
import '../../data/settings_store.dart';
import 'transfer_engine.dart';
import 'transfer_task.dart';

final class AutoTransferService {
  AutoTransferService({
    required this.session,
    required this.engine,
    required this.settings,
    this.destination = TransferDestination.gallery,
    void Function(Object error)? onSkip,
  }) : _onSkip = onSkip {
    _eventsSub = session.events.listen(_onEvent);
  }

  final PtpSession session;
  final TransferEngine engine;
  final SettingsStore settings;
  final TransferDestination destination;
  final void Function(Object error)? _onSkip;

  StreamSubscription<PtpEvent>? _eventsSub;

  /// 最近一次速传入队的句柄(UI 提示「已自动下载」用;null = 无)。
  final _transferred = StreamController<int>.broadcast();
  Stream<int> get transferred => _transferred.stream;

  Future<void> _onEvent(PtpEvent event) async {
    switch (event.code) {
      case PtpEventCode.objectAdded:
      case NikonEventCode.objectAddedInSdram:
        break; // 新对象落地(SDRAM 拍摄走尼康私有码)
      default:
        return;
    }
    if (event.params.isEmpty) return;
    final handle = event.params.first;
    final config = await settings.current();
    if (!config.autoTransfer) return;
    try {
      final info = await session.getObjectInfo(handle);
      final entry = ObjectRepository.toEntry(info);
      if (!formatAllows(entry, config.autoTransferFormat)) {
        return;
      }
      await engine.enqueue([entry], destination: destination);
      _transferred.add(handle);
    } on Exception catch (e) {
      // 相机尚未就绪(连拍清缓存)/对象被删:只丢当张,不断服务
      _onSkip?.call(e);
    }
  }

  /// 格式过滤:视频不受照片格式选择影响;图片按 [format] 选(与
  /// PhotoGroup.membersFor 同语义,单文件粒度);「仅视频」反过来只放行
  /// 视频,照片全部跳过。
  static bool formatAllows(ObjectEntry entry, PhotoDownloadFormat format) {
    if (entry.kind != ObjectKind.image) return true;
    return switch (format) {
      PhotoDownloadFormat.jpg => isJpgFile(entry),
      PhotoDownloadFormat.raw => isRawFile(entry),
      PhotoDownloadFormat.both => true,
      PhotoDownloadFormat.video => false,
    };
  }

  /// 断连/销毁时停听(事件流本身随链路死亡,但显式收口不留悬挂订阅)。
  void dispose() {
    unawaited(_eventsSub?.cancel());
    unawaited(_transferred.close());
  }
}
