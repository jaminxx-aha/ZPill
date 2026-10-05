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
  StorageOverviewController({required this.session, required this.connection}) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        unawaited(refresh());
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        storages = const [];
        notifyListeners();
      }
    });
  }

  final PtpSession session;
  final CameraConnection connection;

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
