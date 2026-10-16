/// 对象仓库:GetObjectHandles → GetObjectInfo 组合(TODO.md §三 P1)。
library;

import 'dart:async';
import 'dart:math' as math;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';
import 'album.dart';
import 'object_entry.dart';
import 'photo_group.dart';

/// 一次增量发布:渐进枚举期间每块完成时广播,末尾一次 [complete] 事件
/// (空相机 / 断点续传零缺口也至少有一次完成事件,订阅方有确定终态)。
final class AlbumsUpdate {
  const AlbumsUpdate({
    required this.albums,
    required this.loaded,
    required this.total,
    required this.complete,
  });

  /// 截至本次发布的相册快照(每块全量重建,不可变)。
  final List<CameraAlbum> albums;

  /// 已处理的对象数(含相机明确拒答而跳过的)。
  final int loaded;

  /// GetObjectHandles 得到的对象总数。
  final int total;

  /// 枚举是否全部完成。
  final bool complete;
}

abstract interface class ObjectRepository {
  /// 相册枚举(渐进):GetObjectHandles 后分块取 ObjectInfo,每块合并入
  /// 缓存并广播到 [updates];本 Future 在**全部块完成**时给出最终快照
  /// (失败则抛出,部分结果已通过 [updates] 发布)。
  /// 并发调用共享同一次枚举(_loading 去重),各订阅者仍能收到全部块。
  Future<List<CameraAlbum>> loadAlbums();

  /// 增量发布流(broadcast):枚举期间的每个块一次;无订阅者时静默。
  Stream<AlbumsUpdate> get updates;

  Future<ObjectEntry> entryFor(int handle);

  /// 从缓存移除已删对象并立即重发布(相机删除后的本地同步,免全量
  /// 重枚举)。空文件夹相册随之自然消失(相册由内容派生)。
  void removeHandles(Iterable<int> handles);

  /// 丢弃缓存并废弃在途枚举(世代计数);断连/手动刷新用。
  void reset();

  /// PtpObjectInfo → ObjectEntry(解析 PTP 日期串、格式码分类、扩展名兜底)。
  static ObjectEntry toEntry(PtpObjectInfo info) {
    var kind = kindForFormatCode(info.objectFormat);
    if (kind == ObjectKind.other) {
      // NEF 的格式码就是 0x3000(真机实测),必须按扩展名二次兜底。
      kind = kindForFilename(info.filename);
    }
    return ObjectEntry(
      handle: info.handle,
      name: info.filename,
      sizeInBytes: info.compressedSize,
      kind: kind,
      parentHandle: info.parentHandle ?? 0,
      // 拍摄时刻缺失回落修改时刻(相机文件拍后不改,两者实际同值)。
      capturedAt:
          _parsePtpDate(info.captureDate) ?? _parsePtpDate(info.modificationDate),
      formatCode: info.objectFormat,
      protectionStatus: info.protectionStatus,
    );
  }

  /// 0x9805 批量属性(单对象的多条 [PtpObjectProp])→ ObjectEntry,字段
  /// 定集与 [toEntry] 一致(文件名/大小/格式码/父夹/时刻)。**文件名
  /// (0xDC07)或格式码(0xDC02)缺失 → null**:该对象交逐对象
  /// GetObjectInfo 路径补(批量快路宁缺毋滥,防无名/无类脏 entry 进相册)。
  /// 不在 GetObjectHandles 结果里的句柄由调用方过滤(TODO 注意事项 2:
  /// 句柄只能来自 GetObjectHandles 响应)。
  static ObjectEntry? toEntryFromProps(
      int handle, Iterable<PtpObjectProp> props) {
    String? name;
    int? format;
    var size = 0;
    var parent = 0;
    var protection = 0;
    String? created;
    String? modified;
    for (final p in props) {
      switch (p.code) {
        case PtpObjectPropCode.objectFilename:
          name = p.value as String?;
        case PtpObjectPropCode.objectFormat:
          format = p.value as int?;
        case PtpObjectPropCode.objectSize:
          size = (p.value as int?) ?? 0;
        case PtpObjectPropCode.parentObject:
          parent = (p.value as int?) ?? 0;
        case PtpObjectPropCode.protectionStatus:
          protection = (p.value as int?) ?? 0;
        case PtpObjectPropCode.dateCreated:
          created = p.value as String?;
        case PtpObjectPropCode.dateModified:
          modified = p.value as String?;
      }
    }
    if (name == null || name.isEmpty || format == null) return null;
    var kind = kindForFormatCode(format);
    if (kind == ObjectKind.other) {
      kind = kindForFilename(name); // NEF 0x3000 同款扩展名兜底
    }
    return ObjectEntry(
      handle: handle,
      name: name,
      sizeInBytes: size,
      kind: kind,
      parentHandle: parent,
      capturedAt: _parsePtpDate(created) ?? _parsePtpDate(modified),
      formatCode: format,
      protectionStatus: protection,
    );
  }

  /// PTP 日期串 `YYYYMMDDThhmmss.s`(UTC)→ DateTime;解析失败返回 null。
  static DateTime? _parsePtpDate(String? raw) {
    if (raw == null || raw.length < 15) return null;
    final y = int.tryParse(raw.substring(0, 4));
    final mo = int.tryParse(raw.substring(4, 6));
    final d = int.tryParse(raw.substring(6, 8));
    final h = int.tryParse(raw.substring(9, 11));
    final mi = int.tryParse(raw.substring(11, 13));
    final s = int.tryParse(raw.substring(13, 15));
    if (y == null || mo == null || d == null || h == null || mi == null || s == null) {
      return null;
    }
    return DateTime.utc(y, mo, d, h, mi, s);
  }
}

/// 基于 [PtpSession] 的实现:GetObjectHandles 一次全量,然后**分块**逐个
/// GetObjectInfo,每块完成即合并入缓存并广播 —— UI 渐进显示最新照片,
/// 其余对象后台同步,不再全屏阻塞等全部 N+1 次往返。
///
/// 填充顺序:句柄倒序(尼康句柄升序 ≈ 拍摄顺序,最新照片低延迟亮相;
/// probe --objmeta 相关性结论若证伪则删反转 —— 只影响出现先后,不影响
/// 最终排序)。批量快路走 MTP 0x9805 GetObjectPropList(官方 §6.2.11.5,
/// 2026-10-15 落地);Nikon 0x9434 GetObjectsMetaData 是候选替代路
/// (探针先行,留真机对比)。
///
/// Zf 真机语义(2026-09-27 实测):parent=0 才是全量枚举(602 个对象,
/// 0xFFFFFFFF 只回根层),故全量走 [GetObjectHandlesParams.parentRoot]。
///
/// 断点续传:中途失败部分结果保留在缓存,重试只补缺失对象。缓存失效:
/// 会话关闭/重连后必须 [reset](AppServices 订阅连接状态驱动),否则句柄
/// 可能已过期。
final class ObjectRepositoryImpl implements ObjectRepository {
  ObjectRepositoryImpl({required this.session, this.chunkSize = 24}) {
    // 拍照即现身:相机落卡 → ObjectAdded(0x4002,中断通道与 0x941C
    // 轮询均汇入 session.events)→ 拉该对象 ObjectInfo 入缓存并广播,
    // 相册免手动刷新(2026-10-16 用户复报「拍的照片要刷新才出现」;
    // 速传/拍摄页小卡早已消费同事件,相册此前漏接)。SDRAM 对象
    // (0xC101)不落卡不入相册,不在此列。App 生命周期订阅:仓库与会
    // 话同寿命,接口无 dispose 不取消(测试随假件一并废弃)。
    session.events.listen(_onEvent);
  }

  void _onEvent(PtpEvent event) {
    if (event.code != PtpEventCode.objectAdded) return;
    if (event.params.isEmpty) return;
    final handle = event.params.first;
    if (_byHandle.containsKey(handle)) return; // 重复事件:已缓存不重拉
    final gen = _generation;
    unawaited(() async {
      try {
        final info = await session.getObjectInfo(handle);
        if (gen != _generation) return; // reset 竞态:弃
        _byHandle[handle] = ObjectRepository.toEntry(info);
        // 枚举进行中不另发布(其分块广播读活缓存,新对象自然带上);
        // 日常拍照(枚举外)即时广播一次完整快照。
        if (_loaded && _loading == null) {
          _publish(_byHandle.length, _byHandle.length, complete: true);
        }
      } on Exception {
        // 新对象已被删/拒答:静默,下次刷新对表
      }
    }());
  }

  final PtpSession session;

  /// 分块大小:每块结束广播一次(602 对象 ≈ 25 次刷新);真机节奏实测后可调。
  final int chunkSize;

  final StreamController<AlbumsUpdate> _updatesCtrl =
      StreamController<AlbumsUpdate>.broadcast(sync: true);

  @override
  Stream<AlbumsUpdate> get updates => _updatesCtrl.stream;

  Map<int, ObjectEntry> _byHandle = <int, ObjectEntry>{};
  bool _loaded = false;

  /// 枚举中标志:并发 loadAlbums/entryFor 共享同一次枚举。
  Future<void>? _loading;

  /// 缓存世代:reset() 递增;在途枚举发现世代不符即停,不再写缓存/发布。
  int _generation = 0;

  /// 缓存是否已建立(全量枚举完成)。
  bool get isLoaded => _loaded;

  @override
  Future<List<CameraAlbum>> loadAlbums() async {
    await _ensureLoaded();
    return _buildAlbums();
  }

  @override
  Future<ObjectEntry> entryFor(int handle) async {
    await _ensureLoaded();
    final entry = _byHandle[handle];
    if (entry == null) {
      throw StateError('对象 0x${handle.toRadixString(16)} 不在缓存(会话已重置?)');
    }
    return entry;
  }

  /// 丢弃缓存(断开/失败后由连接状态监听调用;重连后首次加载重枚举)。
  @override
  void reset() {
    _generation++;
    _byHandle = <int, ObjectEntry>{};
    _loaded = false;
    _loading = null; // 在途枚举由世代计数废弃;新调用立即开新一轮
  }

  @override
  void removeHandles(Iterable<int> handles) {
    var removed = false;
    for (final h in handles.toSet()) {
      if (_byHandle.remove(h) != null) removed = true;
    }
    if (removed) {
      final n = _byHandle.length;
      _publish(n, n, complete: true);
    }
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    final pending = _loading;
    if (pending != null) return pending;
    final load = _loadAll();
    _loading = load;
    // 失败也要清标志,下次调用重试;reset 已换新 _loading 时不覆盖。
    return load.whenComplete(() {
      if (identical(_loading, load)) {
        _loading = null;
      }
    });
  }

  /// 全量枚举(渐进):GetObjectHandles(Zf 语义 parent=0)→ 句柄倒序 →
  /// 跳过已缓存(断点续传)→ **批量快路 0x9805**(一把拿全部对象属性,
  /// 失败/降级静默回退)→ 缺口分块逐个 GetObjectInfo,每块合并入缓存并
  /// 广播到 [updates]。
  Future<void> _loadAll() async {
    final generation = _generation;
    // Zf 把 0 与 0xFFFFFFFF 的语义做反了:parent 必须传 0 才是全量。
    final handles = await session.getObjectHandles();
    // 最新优先(2026-10-02 Zf 实测):GetObjectHandles 线序 =
    // [文件夹][slot-1 照片升序][slot-2 照片升序],槽内句柄升序=拍摄顺序
    // (双槽各对拍 40 条验证)。倒序让最新照片在首个块亮相,文件夹对象
    // 最后到(_publish 的 dropUnnamedFolders 依赖此点)。
    final ordered = handles.reversed.toList(growable: false);
    // 同会话内已删除的对象清出缓存防幽灵;已缓存对象跳过(断点续传)。
    final handleSet = handles.toSet();
    _byHandle.removeWhere((h, _) => !handleSet.contains(h));
    final pending = [
      for (final h in ordered)
        if (!_byHandle.containsKey(h)) h,
    ];

    // ── 批量快路(0x9805,官方 §6.2.11.5):全部对象 × 全部属性一把拿,
    // 1×RTT 替代 N×GetObjectInfo(参数五参全量形 = n-link 生产同款)。
    // 真发失败/数据集不可信在会话层置降级旗标,本会话后续枚举直接
    // 跳过本段;三类批量特有失败在此吞掉走逐对象(行为不回归),链路
    // 级异常(超时/断链)不吞照旧上抛终止枚举。真机核对项:Zf 对
    // 0x9805 的实际支持面与首屏提速实测。
    if (pending.isNotEmpty) {
      List<PtpObjectProp>? props;
      try {
        props = await session.getObjectPropList(
          0xFFFFFFFF, // P1:全部对象
          formatCode: 0x00000000, // P2:全部格式
          propCode: 0xFFFFFFFF, // P3:全部属性
          depth: 0xFFFFFFFF, // P5:整个层级(P4 组码补 0)
        );
      } on UnsupportedError {
        // 本会话已降级(含本次真发失败后的秒拒):直接走逐对象。
      } on PtpResponseException {
        // 相机拒绝 0x9805(op 不在册/参数拒):会话已降级,走逐对象。
      } on FormatException {
        // 数据集不可信(未知类型/计数不符):会话已降级,走逐对象。
      }
      if (generation != _generation) return; // 每个 await 后、写缓存前
      if (props != null) {
        // 按句柄归并(同对象多属性条目分散在流中);不在 GetObjectHandles
        // 结果里的句柄忽略(句柄只能来自 GetObjectHandles,TODO 注意事项 2)。
        final byHandle = <int, List<PtpObjectProp>>{};
        for (final p in props) {
          if (!handleSet.contains(p.handle)) continue;
          byHandle.putIfAbsent(p.handle, () => []).add(p);
        }
        for (final e in byHandle.entries) {
          final entry = ObjectRepository.toEntryFromProps(e.key, e.value);
          if (entry != null) _byHandle[e.key] = entry;
        }
      }
    }

    // 批量缺口(含批量路整体缺席/条目被弃)由既有逐对象路径补齐 ——
    // 断点续传语义天然复用:循环只问缓存里还没有的。
    final gaps = [
      for (final h in pending)
        if (!_byHandle.containsKey(h)) h,
    ];
    if (gaps.length < pending.length) {
      // 批量确有产出:先广播一次「批量已到、缺口未补」的快照。
      _publish(ordered.length - gaps.length, ordered.length, complete: false);
    }
    var loaded = ordered.length - gaps.length;
    var consecutiveFailures = 0;
    for (var start = 0; start < gaps.length; start += chunkSize) {
      final end = math.min(start + chunkSize, gaps.length);
      for (var i = start; i < end; i++) {
        final handle = gaps[i];
        final PtpObjectInfo info;
        try {
          info = await session.getObjectInfo(handle);
        } on PtpResponseException {
          // 相机明确拒答单个对象(如同刻被删):跳过继续;连续 3 个失败
          // 视为会话级拒绝,上抛终止本轮(防空转数百次)。传输层/看门狗
          // 异常不经此捕获,直接终止。
          consecutiveFailures++;
          if (consecutiveFailures >= 3) rethrow;
          loaded++;
          continue;
        }
        consecutiveFailures = 0;
        if (generation != _generation) return; // 每个 await 后、写缓存前
        _byHandle[handle] = ObjectRepository.toEntry(info);
        loaded++;
      }
      if (generation != _generation) return;
      _publish(loaded, ordered.length, complete: false);
    }
    if (generation != _generation) return;
    _loaded = true;
    // 完成事件兜底:空相机 / 续传零缺口(块循环没跑)也要有确定终态。
    _publish(loaded, ordered.length, complete: true);
  }

  /// 广播一次增量快照;未完成发布丢弃未具名文件夹相册(见 _buildAlbums)。
  void _publish(int loaded, int total, {required bool complete}) {
    _updatesCtrl.add(AlbumsUpdate(
      albums: _buildAlbums(dropUnnamedFolders: !complete),
      loaded: loaded,
      total: total,
      complete: complete,
    ));
  }

  /// 派生相册:汇总 + 按文件夹分组(仅 image/video 计入)。
  ///
  /// RAW+JPG 合并([buildPhotoGroups]):同一快门的多个文件归为一个
  /// [PhotoGroup],相册里不再重复显示。同名文件夹(双槽镜像/分存,两槽
  /// 各一个「100NIKON」)并成一个相册瓦片,内容为并集。
  ///
  /// [dropUnnamedFolders]:渐进期间文件夹对象(低句柄,倒序后最后取)可能
  /// 尚未到达 —— true 时这些相册暂不亮相,避免「文件夹 0x11」先占位再
  /// 改名的闪变;最终发布与 [loadAlbums] 返回值用默认 false(兜底名,
  /// 防文件夹对象真缺失时丢相册)。
  List<CameraAlbum> _buildAlbums({bool dropUnnamedFolders = false}) {
    final entries = <ObjectEntry>[
      for (final entry in _byHandle.values)
        if (!entry.isFolder &&
            (entry.kind == ObjectKind.image ||
                entry.kind == ObjectKind.video))
          entry,
    ];
    // 组排序一次,各文件夹相册按遍历序继承(免逐夹重排)。
    final groups = buildPhotoGroups(entries)
      ..sort((a, b) => compareEntries(a.primary, b.primary));

    final byFolder = <int, List<PhotoGroup>>{};
    for (final group in groups) {
      // 双槽分存的组横跨文件夹:涉及的文件夹相册各计入一次。
      for (final folder in group.folderHandles) {
        byFolder.putIfAbsent(folder, () => []).add(group);
      }
    }

    // 同名文件夹并成一个相册(2026-10-03 真机反馈:双槽各有一个
    // 「100NIKON」,列表出两个同名瓦片、各展示同一批合并组 —— 用户
    // 看到「相同文件夹还是有两份」)。句柄取最小保持确定性;内容从
    // 全局序过滤出并集(同一组实例出现在两夹列表里,过滤天然去重)。
    final handlesByName = <String, Set<int>>{};
    for (final folderHandle in byFolder.keys) {
      final folder = _byHandle[folderHandle];
      if (folder == null && dropUnnamedFolders) continue;
      handlesByName
          .putIfAbsent(
              folder?.name ?? '文件夹 0x${folderHandle.toRadixString(16)}',
              () => <int>{})
          .add(folderHandle);
    }
    final folderAlbums = <CameraAlbum>[];
    handlesByName.forEach((name, handles) {
      folderAlbums.add(CameraAlbum(
        name: name,
        folderHandle: handles.reduce(math.min),
        items: List.unmodifiable([
          for (final group in groups)
            if (group.folderHandles.any(handles.contains)) group,
        ]),
      ));
    });
    // 文件夹相册按最新拍摄时间倒序(与相册内照片排序一致),再按名稳定兜底。
    folderAlbums.sort((a, b) {
      final at = a.newestAt;
      final bt = b.newestAt;
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if ((at == null) != (bt == null)) return at == null ? 1 : -1;
      return a.name.compareTo(b.name);
    });

    return [CameraAlbum.allPhotos(groups), ...folderAlbums];
  }

  /// 同层排序:文件夹在前,照片按拍摄时间倒序(新的在前),无时间按名。
  static int compareEntries(ObjectEntry a, ObjectEntry b) {
    if (a.isFolder != b.isFolder) {
      return a.isFolder ? -1 : 1;
    }
    final at = a.capturedAt;
    final bt = b.capturedAt;
    if (at != null && bt != null && at != bt) {
      return bt.compareTo(at);
    }
    if ((at == null) != (bt == null)) {
      return at == null ? 1 : -1;
    }
    return a.name.compareTo(b.name);
  }
}
