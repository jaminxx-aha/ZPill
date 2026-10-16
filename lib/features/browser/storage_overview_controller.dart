/// 存储槽余量控制器(TODO §三 存储空间管理):连接成功后拉
/// GetVendorStorageIDs(0x9209)→ GetStorageInfo,双卡槽余量在概览页
/// 相机信息卡组展示;断连清空。相机拒答(方言差异)静默降级为无面板。
/// application 模式下标准 0x1004 恒回幻影无卡 ID(官方 §6.2.3.1),
/// 真卡 ID 只走 0x9209(2026-10-16 真机定案)。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser/storage_info.dart';
import '../../core/camera/camera_connection.dart';
import '../../core/ptp/operation_codes.dart';
import '../../core/ptp/ptp_session.dart';
import '../../core/ptp/ptp_transport.dart';

final class StorageOverviewController extends ChangeNotifier {
  StorageOverviewController({
    required this.session,
    required this.connection,
    this.connectRefreshDelay = Duration.zero,
  }) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _refreshWhenDue();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _clear();
      }
    });
    _eventsSub = session.events.listen(_onEvent);
  }

  final PtpSession session;
  final CameraConnection connection;

  /// 连接沿刷新让路(生产装配传 2s,测试默认零等待):双卡槽枚举与
  /// 起景链在会话串行锁上轮转,曾把 0x9201 压深 —— 拍摄页「取景未开
  /// 启」卡好几秒(2026-10-16 真机定案)。同概览卡,首帧上屏后再上路。
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

  /// 按槽序展示(按 ID 升序稳定)。
  List<CameraStorage> storages = const [];

  /// 当前记录槽(0xD1F2:0=无卡/1=槽1/2=槽2/3=双槽);null = 未读或拒答。
  int? activeSlot;

  StreamSubscription<CameraLinkState>? _statesSub;
  StreamSubscription<PtpEvent>? _eventsSub;
  Timer? _storeDebounce;
  bool _refreshing = false;

  /// 存储事件追新:插卡/拔卡/余量变化沿 0x4004/0x4005/0x400C,尾沿
  /// 去抖 500ms(连拍/录像期频发合并成一笔刷新,整链才 1+N+1 笔事务,
  /// 不压取景)。
  void _onEvent(PtpEvent e) {
    if (connection.state != CameraLinkState.connected) return;
    switch (e.code) {
      case PtpEventCode.storeAdded ||
          PtpEventCode.storeRemoved ||
          PtpEventCode.storageInfoChanged:
        _storeDebounce?.cancel();
        _storeDebounce = Timer(const Duration(milliseconds: 500), () {
          _storeDebounce = null;
          if (connection.state == CameraLinkState.connected) {
            unawaited(refresh());
          }
        });
      case PtpEventCode.devicePropChanged:
        // 记录槽翻转(相机菜单改记录目的地):轻量单笔重读。
        // 机身是否真推此事件未实证,不推则随下次 refresh 追平。
        if (e.params.isNotEmpty &&
            e.params.first == PtpDevicePropCode.activeSlot) {
          unawaited(_refreshActiveSlot());
        }
    }
  }

  Future<void> _refreshActiveSlot() async {
    if (_refreshing) return; // 全链在途自带 activeSlot,别交叉读
    final slot = await _readActiveSlot();
    if (activeSlot == slot) return;
    activeSlot = slot;
    notifyListeners();
  }

  Future<int?> _readActiveSlot() async {
    try {
      final v =
          await session.getDevicePropValue(PtpDevicePropCode.activeSlot);
      final raw = v.value;
      return raw is int ? raw : null;
    } on Exception {
      return null;
    }
  }

  /// 手动/事件触发刷新(单飞,在途重入直接丢弃)。
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final ids = await session.getVendorStorageIds();
      final infos = <CameraStorage>[];
      for (final id in ids..sort()) {
        try {
          infos.add(await session.getStorageInfo(id));
        } on Exception {
          // 单槽拒答/未插卡:跳过,其余槽照常展示
        }
      }
      activeSlot = await _readActiveSlot();
      storages = infos;
      notifyListeners();
    } on Exception {
      // 整组不支持(方言差异):无面板,不算错误
    } finally {
      _refreshing = false;
    }
  }

  void _clear() {
    _storeDebounce?.cancel();
    _storeDebounce = null;
    storages = const [];
    activeSlot = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _storeDebounce?.cancel();
    unawaited(_eventsSub?.cancel() ?? Future.value());
    unawaited(_statesSub?.cancel() ?? Future.value());
    super.dispose();
  }
}
