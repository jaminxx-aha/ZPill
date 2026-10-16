/// 存储槽余量控制器(TODO §三 存储空间管理):连接成功后拉
/// GetStorageIDs → GetStorageInfo,双卡槽余量在相册页顶展示;
/// 断连清空。相机拒答(如无线方言不支持)静默降级为无面板。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/storage_info.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/ptp/ptp_session.dart';

final class StorageOverviewController extends ChangeNotifier {
  StorageOverviewController({
    required this.session,
    required this.connection,
    this.connectRefreshGate,
  }) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _refreshWhenDue();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        storages = const [];
        notifyListeners();
      }
    });
  }

  final PtpSession session;
  final CameraConnection connection;

  /// 连接沿刷新放行门(生产装配传「起景段落定门」,测试默认 null 直刷):
  /// 双卡槽枚举与起景链在会话串行锁上轮转,曾把 0x9201 压深 —— 拍摄页
  /// 「取景未开启」卡好几秒(2026-10-16 真机定案)。同概览卡,事件驱动:
  /// 起景段(0x9201 含自愈梯)落定即放行,不再死等固定窗。
  final Future<void> Function()? connectRefreshGate;

  void _refreshWhenDue() {
    final gate = connectRefreshGate;
    if (gate == null) {
      unawaited(refresh());
      return;
    }
    unawaited(() async {
      await gate();
      // 门等窗里沿翻篇(断开/重连)不追;重连沿有自己的新定时。
      if (connection.state == CameraLinkState.connected) {
        unawaited(refresh());
      }
    }());
  }

  /// 按槽序展示(按 ID 升序稳定)。
  List<CameraStorage> storages = const [];
  StreamSubscription<CameraLinkState>? _statesSub;
  bool _refreshing = false;

  /// 手动刷新(相机换卡后 StoreAdded 事件不驱动,面板不自动追新)。
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final ids = await session.getStorageIds();
      final infos = <CameraStorage>[];
      for (final id in ids..sort()) {
        try {
          infos.add(await session.getStorageInfo(id));
        } on Exception {
          // 单槽拒答/未插卡:跳过,其余槽照常展示
        }
      }
      storages = infos;
      notifyListeners();
    } on Exception {
      // 整组不支持(方言差异):无面板,不算错误
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel() ?? Future.value());
    super.dispose();
  }
}
