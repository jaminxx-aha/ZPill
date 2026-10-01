/// 真机 PTP 诊断序列(debug 构建,连接成功后自动运行一次)。
///
/// v1 结论(2026-10-01 下午):① 干净态 GetObject 即 0x200F(排除
/// 缩略图操作毒化会话);getThumb 全 0x200F;app 解析的
/// operationsSupported 不含 0x100A/0x90C4(与 9-27 Mac 探针
/// 「0x90C4 在册」矛盾)。
///
/// v2 分叉验证(每项独立回答一个问题):
/// ② 按 parentHandle / storageId 限定枚举,对比同一文件的句柄取值与
///    数据可达性 —— 「parent=0 平铺视图给虚拟句柄」假设(阶段 E 按
///    文件夹枚举句柄能下载,现相册模型用平铺句柄全被拒,这是两条
///    流程最大的差异);
/// ⑤ CloseSession→OpenSession 后复测 —— 会话状态假设(顺带观察重开
///    后句柄是否仍有效);
/// ⑥ GetPartialObject(0x101B)与 0x90C4(force 直发)—— data-in 类
///    操作是否整体被拒 + 能力表可信度;
/// 另全量 dump operationsSupported / eventsSupported —— 解析错位自查。
///
/// 输出走 debugPrint → hilog(标签 [PTP诊断])。
/// 诊断用完不删:后续协议层改动(0x9434、断点续传等)真机首验可复用。
library;

import 'package:flutter/foundation.dart';

import '../core/browser/object_entry.dart';
import '../core/browser/object_repository.dart';
import '../core/ptp/ptp_session.dart';
import '../core/ptpip/object_format.dart';

final class PtpDiagnostics {
  PtpDiagnostics._();

  static void _p(Object? msg) => debugPrint('[PTP诊断] $msg');

  static String _h(int v) => '0x${v.toRadixString(16)}';

  /// 连接成功后由 AppServices 触发;自带异常兜底,永不抛出。
  static Future<void> run({
    required PtpSession session,
    required ObjectRepository repository,
  }) async {
    try {
      await _run(session, repository);
    } catch (e, s) {
      _p('诊断自身异常: $e');
      _p('$s');
    }
  }

  static Future<void> _run(
    PtpSession session, ObjectRepository repository) async {
    if (!kDebugMode) return;
    _p('── 开始 v2 ──');

    final info = await session.getDeviceInfo(); // 命中缓存,无线上流量
    _p('device=${info.model} std=${info.standardVersion} '
        'vendor=${_h(info.vendorExtensionId)} ver=${info.deviceVersion} '
        'mode=${info.functionalMode}');
    // 能力表全量 dump,12 码一行(hilog 单行截断防御)。
    for (var i = 0; i < info.operationsSupported.length; i += 12) {
      final row = info.operationsSupported
          .skip(i)
          .take(12)
          .map(_h)
          .join(' ');
      _p('ops[$i+] $row');
    }
    _p('events=${info.eventsSupported.map(_h).join(' ')}');

    // 枚举与 UI 共享同一次(_ensureLoaded 去重)。
    final albums = await repository.loadAlbums();
    final items = albums.isEmpty ? const <ObjectEntry>[] : albums.first.items;
    _p('albums=${albums.length} photos=${items.length}');

    final images = [
      for (final e in items)
        if (e.kind == ObjectKind.image) e,
    ]..sort((a, b) => a.sizeInBytes.compareTo(b.sizeInBytes));
    final smallest = images.isEmpty ? null : images.first;
    if (smallest == null) {
      _p('无图片对象,序列终止');
      return;
    }

    // 采样对象原始 ObjectInfo(storageId 关系到双卡槽判定)。
    final oi = await session.getObjectInfo(smallest.handle);
    _p('sample ${smallest.name} handle=${_h(smallest.handle)} '
        'storageId=${_h(oi.storageId)} format=${_h(oi.objectFormat)} '
        'size=${oi.compressedSize} parent=${_h(oi.parentHandle ?? 0)}');

    _p('① GetObject(平铺句柄基线, ${smallest.name})');
    await _drain(session, smallest.name, smallest.handle);
    await _thumb(session, '① getThumb(平铺句柄)', smallest.handle);

    // ② 限定枚举对比:同一文件在「parent=文件夹」「storageId=卡槽」
    // 视图下的句柄是否与平铺视图一致,数据操作是否可达。
    final parent = oi.parentHandle ?? 0;
    _p('② 文件夹枚举(parent=${_h(parent)}, ${smallest.name} 所在)');
    await _scopedProbe(
      session,
      label: '② parent=${_h(parent)}',
      wantName: smallest.name,
      flatHandle: smallest.handle,
      find: () => session.getObjectHandles(parent: parent),
    );
    _p('② 卡槽枚举(storageId=${_h(oi.storageId)}, parent=0)');
    await _scopedProbe(
      session,
      label: '② storage=${_h(oi.storageId)}',
      wantName: smallest.name,
      flatHandle: smallest.handle,
      find: () => session.getObjectHandles(storageId: oi.storageId),
    );

    // ⑤ 会话重置:CloseSession → OpenSession → 复测(句柄是否失效、
    // 拒绝是否随会话消失)。
    _p('⑤ 会话重置 close→open');
    await session.close();
    await session.open();
    _p('重开完成 isSessionOpen=${session.isSessionOpen}');
    try {
      final oi2 = await session.getObjectInfo(smallest.handle);
      _p('重开后 getObjectInfo(同 handle) OK name=${oi2.filename}');
    } catch (err) {
      _p('重开后 getObjectInfo(同 handle) 失败: $err');
    }
    await _drain(session, '⑤ GetObject(重开, 平铺句柄)', smallest.handle);

    // ⑥ 替代数据通路直发:不做能力检查,直接看相机响应码。
    _p('⑥ GetPartialObject(0x101B, 平铺句柄)');
    await _partial(session, '⑥ 0x101B(平铺)', smallest.handle);
    _p('⑥ 0x90C4 GetLargeThumb(force 直发, 平铺句柄)');
    await _largeThumb(session, '⑥ 0x90C4(平铺)', smallest.handle);
    _p('── 结束 ──');
  }

  /// 限定视图枚举 → 找 [wantName] → 对比句柄([flatHandle] = 平铺视图
  /// 里的同文件句柄)并测数据操作。
  static Future<void> _scopedProbe(
    PtpSession session, {
    required String label,
    required String wantName,
    required int flatHandle,
    required Future<List<int>> Function() find,
  }) async {
    try {
      final handles = await find();
      _p('$label 枚举到 ${handles.length} 个对象');
      int? scoped;
      for (final h in handles) {
        final oi = await session.getObjectInfo(h);
        if (oi.filename == wantName) {
          scoped = h;
          break;
        }
      }
      if (scoped == null) {
        _p('$label 中未找到 $wantName');
        return;
      }
      _p('$label 句柄=${_h(scoped)} '
          '(与平铺句柄${scoped == flatHandle ? '相同' : '不同!!'})');
      await _drain(session, '$label GetObject', scoped);
      await _thumb(session, '$label getThumb', scoped);
    } catch (err) {
      _p('$label 枚举失败: $err');
    }
  }

  static Future<void> _drain(
      PtpSession session, String label, int handle) async {
    try {
      final watch = Stopwatch()..start();
      var bytes = 0;
      await session.getObject(handle, onData: (c) => bytes += c.length);
      watch.stop();
      final mbps = bytes / 1e6 / (watch.elapsed.inMicroseconds * 1e-6);
      _p('GetObject($label) OK ${bytes}B ${mbps.toStringAsFixed(2)}MB/s');
    } catch (err) {
      _p('GetObject($label) 失败: $err');
    }
  }

  static Future<void> _thumb(
      PtpSession session, String label, int handle) async {
    try {
      final d = await session.getThumb(handle);
      _p('getThumb($label) OK ${d.length}B head=${_hex(d, 16)}');
    } catch (err) {
      _p('getThumb($label) 失败: $err');
    }
  }

  static Future<void> _largeThumb(
      PtpSession session, String label, int handle) async {
    try {
      final d = await session.getLargeThumb(handle, force: true);
      _p('0x90C4($label) OK ${d.length}B head=${_hex(d, 16)}');
    } catch (err) {
      _p('0x90C4($label) 失败: $err');
    }
  }

  static Future<void> _partial(
      PtpSession session, String label, int handle) async {
    try {
      final d = await session.getPartialObject(handle, 0, 2048);
      _p('GetPartialObject($label) OK ${d.length}B head=${_hex(d, 16)}');
    } catch (err) {
      _p('GetPartialObject($label) 失败: $err');
    }
  }

  static String _hex(Uint8List d, int n) {
    final take = d.length < n ? d.length : n;
    return [
      for (var i = 0; i < take; i++)
        d[i].toRadixString(16).padLeft(2, '0').toUpperCase(),
    ].join(' ');
  }
}
