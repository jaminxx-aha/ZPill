/// 存储槽余量控制器:连接成功后拉
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
  }) {
    _statesSub = connection.states.listen((s) {
      if (s == CameraLinkState.connected) {
        _linkUp = true;
        _refreshWhenDue();
      } else if (s == CameraLinkState.disconnected ||
          s == CameraLinkState.failed) {
        _linkUp = false;
        _clear();
      }
    });
    _eventsSub = session.events.listen(_onEvent);
  }

  final PtpSession session;
  final CameraConnection connection;

  /// 连接沿即拉,不再等起景门(2026-11-05):卡槽信息是静态数据,连
  /// 接页要对用户可见;整链 1+N+1 笔小事务(两槽 = 4 笔)压在 0x9201
  /// 前的代价远小于陪等起景段 1-3s。每槽读回即 notify,首槽先亮,
  /// 不等记录槽尾读。
  void _refreshWhenDue() {
    unawaited(refresh());
  }

  /// 按槽序展示(按 ID 升序稳定)。
  List<CameraStorage> storages = const [];

  /// 当前记录槽(0xD1F2:0=无卡/1=槽1/2=槽2/3=双槽);null = 未读或拒答。
  int? activeSlot;

  /// 连接门闩(状态流驱动,与 connection.state 解耦):连接沿即发后,
  /// 断连/重连可能穿插在刷新链中,迟到结果据此丢弃。
  bool _linkUp = false;

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
  ///
  /// 逐槽渐进:每读回一槽即入列 notify(连接页首槽先亮),记录槽
  /// (0xD1F2)单笔尾读只更新台账高亮,不挡卡信息本身。
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final ids = await session.getVendorStorageIds();
      // 连接沿即发后,断连/重连可能穿插在链中:每步收口前确认真源仍是
      // 已连接态,迟到结果不覆盖 _clear 后的空态。
      if (!_linkUp) return;
      final infos = <CameraStorage>[];
      for (final id in ids..sort()) {
        try {
          infos.add(await session.getStorageInfo(id));
          if (!_linkUp) return;
          storages = List<CameraStorage>.unmodifiable(infos);
          notifyListeners();
        } on Exception {
          // 单槽拒答/未插卡:跳过,其余槽照常展示
        }
      }
      activeSlot = await _readActiveSlot();
      if (!_linkUp) return;
      storages = List<CameraStorage>.unmodifiable(infos);
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
