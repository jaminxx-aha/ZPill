/// 对象仓库:GetObjectHandles → GetObjectInfo 组合。
library;

import 'dart:async';
import 'dart:math' as math;

import '../ptpip/object_format.dart';
import '../ptpip/object_info.dart';
import '../ptp/operation_codes.dart';
import '../ptp/ptp_session.dart';
import '../ptp/ptp_transport.dart';
import '../log/app_log.dart';
import '../media/video_rating.dart';
import '../media/video_duration.dart';
import '../utils/byte_reader.dart';
import '../utils/byte_writer.dart';
import 'album.dart';
import 'object_entry.dart';
import 'photo_group.dart';

/// MTP Rating 原始值(u16,官方 §6.6.3.3)→ 星(0-5):0/1/25/50/75/100
/// 六个合法值,表外值按档位向下取整(相机写入侧同规,§6.6.3.3 例 60→50)。
/// **>100 的野值(错位/垃圾字节)按未评处理** —— 防脚本/链路错位把
/// 垃圾字节抬成 ★5。
int ratingRawToStars(int raw) => raw > 100
    ? 0
    : raw >= 100
        ? 5
        : raw >= 75
            ? 4
            : raw >= 50
                ? 3
                : raw >= 25
                    ? 2
                    : raw >= 1
                        ? 1
                        : 0;

/// 星(0-5)→ MTP Rating 原始值(§6.6.3.3 合法档,0 = 清除评级)。
int starsToRatingRaw(int stars) =>
    const [0, 1, 25, 50, 75, 100][stars.clamp(0, 5)];

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
  /// 相册枚举(渐进):GetObjectHandles 后按日期目录分页取属性
  /// (0x9805,逐对象回退),每页/每块合并入缓存并广播到 [updates];
  /// 本 Future 在**全部完成**时给出最终快照
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

  /// 相机评级数据是否已建立(MTP 0xDC8A;徽标/筛选只在此下展示,
  /// 防「未取到」被当「未评」)。
  bool get ratingsLoaded;

  /// 请求拉取某句柄的相机评级(逐张 0x9803;批量收割已被真机证伪)。
  /// [trashProbe] 放行时图像兼做 256KB XMP 删除候选甄别(昂贵大读,
  /// 网格轻量沿传 false,驻留沿走 [requestTrashProbe])。fire-and-forget:
  /// 重复请求/在途/不在册空转,成果经 [updates] 发布。
  void requestRating(int handle, {bool trashProbe = true});

  /// 补发删除候选甄别(图像 256KB XMP 头读,NEF 兼档位兜底;视频已随
  /// NCTG 走完空转)。与 [requestRating]/后台甄别共去重集,不重发。
  void requestTrashProbe(int handle);

  /// 视频时长(容器 mvhd 解析;null = 未探测/探测失败)。
  Duration? durationFor(int handle);

  /// 请求探测视频时长(容器行走,数次小读;去重,fire-and-forget,
  /// 成果经 [updates] 发布)。
  void requestVideoDuration(int handle);

  /// 单文件评级(0 = 未评/未取到)。
  int ratingForHandle(int handle);

  /// 组评级 = 成员最大值(RAW+JPG 相机侧逐文件评级,任一有星即展示)。
  int ratingForGroup(PhotoGroup group);

  /// 单文件「已评级·档位未知」(0x9434 bit0=1 但 0x9803 拒答且 XMP 头
  /// 读无标记,NEF 形态)。
  bool ratedUnknownFor(int handle);

  /// 组「已评级·档位未知」:全组成员都无已知档位但有未知档成员。
  bool groupRatedUnknown(PhotoGroup group);

  /// 单文件删除候选(机身「垃圾桶」态;协议落点待取证,暂由
  /// 位图有星 + 读回 0 判定)。
  bool trashMarkedFor(int handle);

  /// 组删除候选:无已知档位、无未知档成员、有删除候选成员。
  bool groupTrashStar(PhotoGroup group);

  /// 句柄 → 所在组(XMP 注入/落盘快照按组取评级用);不在册 = null。
  PhotoGroup? groupOf(int handle);

  /// 改评(组粒度,0 = 清除;写 0x9804,乐观上屏失败回滚,见实现)。
  Future<void> rateGroup(PhotoGroup group, int stars);

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
  /// 不在 GetObjectHandles 结果里的句柄由调用方过滤(句柄只能来自
  /// GetObjectHandles 响应)。
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

/// 基于 [PtpSession] 的实现:GetObjectHandles 一次全量句柄,然后**按
/// 日期目录分页**取属性(0x9805 depth=1,页到即合并即广播)—— UI 首页
/// 照片 ~1s 亮相,不等全库(2026-10-17 真机探针:0x9805 编目成本按对象
/// 数线性、相机端无固定编目成本,全库一笔 3.8~8.3s;分页不省总时长但
/// 消首屏等待)。根层没探出日期目录或批量路降级/被拒时,逐对象
/// GetObjectInfo 分块补齐(断点续传语义同路)。
///
/// 填充顺序:句柄倒序(尼康句柄升序 ≈ 拍摄顺序,最新照片低延迟亮相;
/// probe --objmeta 相关性结论若证伪则删反转 —— 只影响出现先后,不影响
/// 最终排序)。Nikon 0x9434 GetObjectsMetaData 是候选替代路(探针先行,
/// 留真机对比)。
///
/// Zf 真机语义(2026-09-27 实测):parent=0 才是全量枚举(602 个对象,
/// 0xFFFFFFFF 只回根层),故全量走 [GetObjectHandlesParams.parentRoot],
/// 分页的页发现(根层)走 parentAll。
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
    if (event.code == PtpEventCode.objectInfoChanged) {
      _onObjectInfoChanged(event);
      return;
    }
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

  /// 0x4007 ObjectInfoChanged(§6.4.1.7):对象信息变化(相机侧改评是
  /// 其一;是否真发未证)。best-effort 重拉该对象评级 —— 相机→App
  /// 两向同步的落点;失败静默,下次重枚举对表。
  void _onObjectInfoChanged(PtpEvent event) {
    if (event.params.isEmpty) return;
    final handle = event.params.first;
    if (!_byHandle.containsKey(handle) || _loading != null) {
      return; // 枚举中不另发:块发布重建相册自然带上
    }
    unawaited(_fetchRating(handle, force: true)); // 事件重拉:越过已问集
    // NEF 等档位拿不到的成员:星级变化只能靠位图重同步(去抖 1s 合窗)。
    if (!isRatingCapable(_byHandle[handle]!)) {
      _metaResyncTimer?.cancel();
      final gen = _generation;
      _metaResyncTimer = Timer(const Duration(seconds: 1), () {
        if (gen != _generation) return;
        unawaited(() async {
          try {
            for (final m in await session.getObjectsMetaData()) {
              if (gen != _generation) return;
              if (m.hasRating) {
                _metaRated.add(m.handle);
                final entry = _byHandle[m.handle];
                if (entry != null && !isRatingCapable(entry)) {
                  _ratedUnknown.add(m.handle);
                }
              } else {
                _metaRated.remove(m.handle);
                _ratedUnknown.remove(m.handle);
                _ratings.remove(m.handle);
              }
            }
            _scheduleRatingPublish();
          } on Exception {
            // 重同步失败:静默,下次枚举对表
          }
        }());
      });
    }
  }

  /// 逐张评级读取(0x9803,官方 §6.2.11.3):批量收割已被真机证伪
  /// (0x9805 按属性恒 0xA801,全属性应答不携带),评级数据只能这样
  /// 一张一张拉。JPEG 成功即缓存+合并发布;NEF/拒答形态记入
  /// [_ratingQueried] 不再重试;失败不抛(评级是加菜)。
  Future<bool> _fetchRating(int handle, {bool force = false}) async {
    if (!force && !_ratingQueried.add(handle)) return false;
    if (!_ratingInFlight.add(handle)) return false;
    final gen = _generation;
    try {
      final value =
          await session.getObjectPropValue(handle, PtpObjectPropCode.rating);
      if (gen != _generation) return false;
      if (value.length >= 2) {
        _ratings[handle] = ratingRawToStars(ByteReader(value).u16());
        _ratingsSeen = true;
        _ratedUnknown.remove(handle); // 档位到手,未知态解除
        _scheduleRatingPublish();
        return true;
      }
    } on Object {
      if (_metaRated.contains(handle)) {
        // 位图有星但 0xDC8A 拒(NEF 形态,真机 0xA80A):NEF 文件头
        // 64KB 内嵌 XMP 明文带 xmp:Rating(真机 ★1 实证)—— 头读兜底
        // 拿档位;拿不到(JPEG/MP4 不嵌/读失败)才落「已评级·未知」。
        final stars = await _ratingFromXmpHead(handle);
        if (stars != null) {
          _ratings[handle] = stars;
          _ratingsSeen = true;
          _ratedUnknown.remove(handle);
          _scheduleRatingPublish();
          return true;
        }
        _ratedUnknown.add(handle);
        _ratingsSeen = true;
        _scheduleRatingPublish();
      }
      // 非位图有星的拒答(无星对象的例行探测):静默
    } finally {
      _ratingInFlight.remove(handle);
    }
    return false;
  }

  /// xmp:Rating 头读兜底:NEF 等 0xDC8A 拒答格式从文件头 64KB 抠档位
  /// (NEF 的 XMP 是 TIFF 结构随文件头;JPEG 实测不嵌评级,MP4 的在
  /// 尾部 moov,头读都落空 —— 此兜底只为嵌头部的格式存在)。
  static final RegExp _xmpRatingPattern =
      RegExp(r'<xmp:Rating>(-?\d+)</xmp:Rating>');

  Future<int?> _ratingFromXmpHead(int handle) async {
    try {
      final head = await session.getPartialObject(handle, 0, 65536);
      final match =
          _xmpRatingPattern.firstMatch(String.fromCharCodes(head));
      if (match == null) return null;
      final stars = int.tryParse(match.group(1)!);
      return stars == null || stars < 1 || stars > 5 ? null : stars;
    } on Object {
      return null; // 头读失败/无标记:调用方落未知档
    }
  }

  /// 评级更新合并发布(300ms 窗):后台补读逐张到达,合窗防重建风暴。
  void _scheduleRatingPublish() {
    if (_ratingPublishTimer != null) return;
    _ratingPublishTimer = Timer(const Duration(milliseconds: 300), () {
      _ratingPublishTimer = null;
      if (_loading != null) return; // 枚举中:块发布自然带上
      _publish(_byHandle.length, _byHandle.length, complete: true);
    });
  }

  /// 评级即时发布(按需沿):可见格先答的意义就是不等合窗。
  void _publishRatingsNow() {
    _ratingPublishTimer?.cancel();
    _ratingPublishTimer = null;
    if (_loading != null) return; // 枚举中:块发布自然带上
    _publish(_byHandle.length, _byHandle.length, complete: true);
  }

  /// 请求拉取某句柄的评级(网格格 build / 查看器翻页沿按需即发,后台
  /// 顺序队的插队口):按格式分流 —— 视频走容器 NCTG(星档+删除候选
  /// 一笔流);图像先 0xDC8A 拉星档(NEF 必拒,跳过),[trashProbe] 放行
  /// 时位图外再 256KB XMP 甄别删除候选 —— 两段串行(并发会同抢在途
  /// 去重互吞)。各段完成即发布(跳过 300ms 合并窗,可见格先答的意义
  /// 就是不等)。各路自有去重集,重复调用空转。fire-and-forget。
  @override
  void requestRating(int handle, {bool trashProbe = true}) {
    final entry = _byHandle[handle];
    if (entry == null || entry.isFolder) return;
    switch (entry.kind) {
      case ObjectKind.video:
        unawaited(() async {
          await _detectTrashViaNctg(entry);
          _publishRatingsNow();
        }());
      case ObjectKind.image:
        unawaited(() async {
          if (isRatingCapable(entry)) {
            await _fetchRating(handle); // 星档(位图有星 0xDC8A/拒走 XMP 兜底)
            _publishRatingsNow(); // 便宜一笔,即读即上屏,不等甄别
          }
          if (trashProbe && !_metaRated.contains(handle)) {
            await _detectTrashViaXmp(handle); // 删除候选(NEF 兼档位兜底)
            _publishRatingsNow();
          }
        }());
      default:
        break;
    }
  }

  /// 驻留沿补删除候选甄别(网格格驻留 ~400ms 仍在树上才发):图像
  /// 256KB XMP 头读,视频已随 NCTG 走完空转。fire-and-forget。
  @override
  void requestTrashProbe(int handle) {
    final entry = _byHandle[handle];
    if (entry == null || entry.isFolder) return;
    if (entry.kind != ObjectKind.image) return;
    unawaited(() async {
      // 驻留沿可能与轻量段 fetch 在途撞车:_detectTrashViaXmp 先登记
      // 已甄别再撞在途门,撞车 = 静默吞 + 永久记「已甄别」—— 先等收口。
      while (_ratingInFlight.contains(handle)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await _detectTrashViaXmp(handle);
      _publishRatingsNow();
    }());
  }

  final Map<int, Duration> _videoDurations = {};
  final Set<int> _videoDurationQueried = {};

  @override
  Duration? durationFor(int handle) => _videoDurations[handle];

  @override
  void requestVideoDuration(int handle) {
    final entry = _byHandle[handle];
    if (entry == null || entry.kind != ObjectKind.video) return;
    if (!_videoDurationQueried.add(handle)) return;
    unawaited(() async {
      try {
        final d = await readVideoDuration((off, len) async {
          try {
            return await session.getPartialObject(handle, off, len);
          } on Object {
            return null;
          }
        });
        if (d != null) {
          _videoDurations[handle] = d;
          _scheduleRatingPublish(); // 借评级发布管线广播(页侧重建取值)
        }
      } on Object {
        // 探测失败:不显时长
      }
    }());
  }

  /// 评级回退补读(0x9434 不可用时的旧路):按缓存序(新→旧)逐适用
  /// 格式 0x9803 拉,张间留 30ms 缝让取景帧/用户操作插队(会话串行锁
  /// 天然保证优先级,这里只是别把队列一次排死)。起步延 500ms(枚举沿
  /// UI 先落定,测试断言窗口不被补读请求闯入);世代计数防 reset 后空转。
  Future<void> _fillRatingsInBackground(int generation) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final entry in _byHandle.values.toList(growable: false)) {
      if (generation != _generation) return;
      if (entry.isFolder || !isRatingCapable(entry)) continue;
      if (_ratingQueried.contains(entry.handle)) continue;
      await _fetchRating(entry.handle);
      if (generation != _generation) return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  /// 分块大小:每块结束广播一次(602 对象 ≈ 25 次刷新);真机节奏实测后可调。
  final int chunkSize;

  final StreamController<AlbumsUpdate> _updatesCtrl =
      StreamController<AlbumsUpdate>.broadcast(sync: true);

  @override
  Stream<AlbumsUpdate> get updates => _updatesCtrl.stream;

  Map<int, ObjectEntry> _byHandle = <int, ObjectEntry>{};
  bool _loaded = false;

  /// 相机评级缓存(句柄 → 0-5 星;0 = 未评/未知)。真源 = 相机
  /// (MTP 0xDC8A,官方 §6.6.3.3)。真机定案(2026-10-22 Zf 双链):
  /// **只对 JPEG(0x3801)开门** —— 0x9803 读/0x9804 写 OK;NEF 0x3000
  /// 0xA80A/0xA801 拒(合规);0x9805 按属性批量(含全属性携带)恒
  /// 0xA801 拒 —— 批量收割是死路,评级只能逐张 0x9803 拉(见
  /// [requestRating] 与枚举完成后的后台补读)。
  final Map<int, int> _ratings = <int, int>{};

  /// 已发过评级读取的句柄(含失败 —— NEF 等拒答形态不重试,防逐张硬敲)。
  final Set<int> _ratingQueried = <int>{};

  /// 在途评级读取(去重)。
  final Set<int> _ratingInFlight = <int>{};

  /// 评级更新发布合并器:后台补读每张一张,逐张发会导致相册全量重建
  /// 风暴 —— 300ms 内的更新合一次发布。
  Timer? _ratingPublishTimer;

  /// 本会话已见过真实评级数据(徽标/筛选只在此下展示,防「未取到」
  /// 被当「未评」)。
  bool _ratingsSeen = false;

  /// 0x9434 批量位(bit0)判「有星」的句柄 —— 全格式可得(含 NEF;
  /// 2026-10-22 真机实证,24 元素 16B 布局)。
  final Set<int> _metaRated = <int>{};

  /// 有星但**档位拿不到**的句柄(NEF 等 0x9803 拒答形态):展示为
  /// 「已评级·星级未知」,筛选归「已评级」。
  final Set<int> _ratedUnknown = <int>{};

  /// **删除候选**(机身「垃圾桶」态)—— 判据(2026-10-22 真机 7 态
  /// 标定 + 复标实证):JPEG/HIF/NEF 头 256KB 的 XMP 包 `xmp:Rating`
  /// **= -1 即删除候选**(0 = 无评级,1-5 = 星档;协议 0xDC8A 对垃圾
  /// 桶读 0、位图不置位,文件 XMP 是唯一区分通道)。仅对头嵌 XMP 的
  /// 图像格式可判(视频容器摸不到,其删除候选不可见 —— 已知限制)。
  final Set<int> _trashMarked = <int>{};

  /// 0x4007 触发的 0x9434 重同步去抖(NEF 星级档位拿不到,重拉全卡位图)。
  Timer? _metaResyncTimer;

  /// 删除候选甄别去重(独立于 [_ratingQueried] —— 查看器沿的 0xDC8A
  /// 读只回答「星档」,回答不了垃圾桶;两路互不占坑)。
  final Set<int> _trashProbed = <int>{};

  /// 枚举中标志:并发 loadAlbums/entryFor 共享同一次枚举。
  Future<void>? _loading;

  /// 缓存世代:reset() 递增;在途枚举发现世代不符即停,不再写缓存/发布。
  int _generation = 0;

  /// 缓存是否已建立(全量枚举完成)。
  bool get isLoaded => _loaded;

  /// 本会话评级数据是否已建立(枚举批量携带或探针补齐)。
  @override
  bool get ratingsLoaded => _ratingsSeen;

  /// 单文件评级(0 = 未评/未取到)。
  @override
  int ratingForHandle(int handle) => _ratings[handle] ?? 0;

  /// 组评级 = 成员最大值:RAW+JPG 相机侧逐文件评级,任一有星即展示
  /// (代表件优先看到的与回写目标都是全成员,口径一致)。
  @override
  int ratingForGroup(PhotoGroup group) {
    var stars = 0;
    for (final m in group.members) {
      final s = _ratings[m.handle] ?? 0;
      if (s > stars) stars = s;
    }
    return stars;
  }

  /// 单文件「已评级·档位未知」(0x9434 bit0=1 但 0x9803 拒答,NEF 形态)。
  @override
  bool ratedUnknownFor(int handle) =>
      _ratedUnknown.contains(handle) && (_ratings[handle] ?? 0) == 0;

  /// 组「已评级·档位未知」:全组成员都无已知档位但有未知档成员。
  @override
  bool groupRatedUnknown(PhotoGroup group) =>
      ratingForGroup(group) == 0 &&
      group.members.any((m) => ratedUnknownFor(m.handle));

  /// 单文件删除候选(头 256KB XMP Rating=-1;仅图像格式可判)。
  @override
  bool trashMarkedFor(int handle) =>
      _trashMarked.contains(handle) && (_ratings[handle] ?? 0) == 0;

  /// 组删除候选:无已知档位、无未知档成员、有删除候选成员。
  @override
  bool groupTrashStar(PhotoGroup group) =>
      ratingForGroup(group) == 0 &&
      !groupRatedUnknown(group) &&
      group.members.any((m) => trashMarkedFor(m.handle));

  /// 句柄 → 所在组(XMP 注入/落盘评级快照按组取评级用);不在册返回
  /// null(仓库未加载也 null)。
  @override
  PhotoGroup? groupOf(int handle) {
    if (!_loaded) return null;
    for (final group in _buildAlbums().first.items) {
      if (group.members.any((m) => m.handle == handle)) return group;
    }
    return null;
  }

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
    _ratings.clear();
    _ratingQueried.clear();
    _ratingInFlight.clear();
    _metaRated.clear();
    _ratedUnknown.clear();
    _trashMarked.clear();
    _trashProbed.clear();
    _ratingPublishTimer?.cancel();
    _ratingPublishTimer = null;
    _metaResyncTimer?.cancel();
    _metaResyncTimer = null;
    _ratingsSeen = false;
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

  /// 全量枚举(渐进,分页快路):GetObjectHandles(Zf 语义 parent=0)
  /// 全量句柄 → 根层逐根 0x9805 depth=1 探日期目录 → 目录按名降序逐页
  /// 0x9805 depth=1(页 = 日期目录),每页合并入缓存即广播,页间留
  /// [pageGap] 让取景帧插队 —— 首页照片 ~1s 亮相,不等全库。根层没探
  /// 出日期目录时退全库一笔(旧全量形);批量特有失败(降级/拒答/
  /// 数据集不可信)整段弃页单,由逐对象缺口对账兜底(行为不回归);链路
  /// 级异常(超时/断链)不吞照旧上抛。
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
    var loaded = ordered.length - pending.length;

    // ── 分页快路(0x9805 按日期目录分片,官方 §6.2.11.5):根层(Zf
    // 语义 parent=0xFFFFFFFF 只回根对象)逐根 depth=1 展开一层即日期
    // 目录,目录对象顺带入册得具名;页序名降序 = 新目录先出(尼康目录
    // 号随时间递增)。任一笔批量失败整段弃页单走逐对象。
    final pages = <({int handle, String name})>[];
    if (pending.isNotEmpty && !session.objectPropListDegraded) {
      try {
        final roots = await session.getObjectHandles(
            parent: GetObjectHandlesParams.parentAll);
        if (generation != _generation) return;
        for (final root in roots) {
          final added = _absorbProps(
            await session.getObjectPropList(root, depth: 1),
            handleSet,
          );
          if (generation != _generation) return;
          loaded += added.length;
          // 页 = 被探根的直接子目录(0xDC04 parentObject 定归属;根自身
          // parent=0 天然排除)。
          for (final f in added) {
            if (f.isFolder && f.parentHandle == root) {
              pages.add((handle: f.handle, name: f.name));
            }
          }
        }
        // 同名页(双槽同名目录)取大句柄兜底稳定。
        pages.sort((a, b) {
          final byName = b.name.compareTo(a.name);
          return byName != 0 ? byName : b.handle.compareTo(a.handle);
        });
        for (var i = 0; i < pages.length; i++) {
          if (i > 0) {
            // 页间让路:页事务 ~0.5-1s 占住串行锁,缝里让排队的取景帧
            // 插队(帧 50ms 一轮,150ms 够走 2-3 帧),起景后预热不打
            // 取景(首页前不留缝,首屏不付此税)。
            await Future<void>.delayed(pageGap);
            if (generation != _generation) return;
          }
          loaded += _absorbProps(
            await session.getObjectPropList(pages[i].handle, depth: 1),
            handleSet,
          ).length;
          if (generation != _generation) return;
          // 页到即发:该目录的照片此沿亮相,不等其余页与缺口。
          _publish(loaded, ordered.length, complete: false);
        }
        if (pages.isEmpty) {
          // 根层没探出日期目录(根枚举空/子层无目录):退全库一笔(旧
          // 全量形,n-link 生产同款),别把几百个对象全推给逐对象。
          loaded += _absorbProps(
            await session.getObjectPropList(
              0xFFFFFFFF, // P1:全部对象
              formatCode: 0x00000000, // P2:全部格式
              propCode: 0xFFFFFFFF, // P3:全部属性
              depth: 0xFFFFFFFF, // P5:整个层级(P4 组码补 0)
            ),
            handleSet,
          ).length;
          if (generation != _generation) return;
        }
      } on UnsupportedError {
        // 本会话已降级(含本次真发失败后的秒拒):弃页单,走逐对象。
      } on PtpResponseException {
        // 相机拒绝 0x9805(op 不在册/参数拒):会话已降级,走逐对象。
      } on FormatException {
        // 数据集不可信(未知类型/计数不符):会话已降级,走逐对象。
      }
    }

    // 分页未覆盖的缺口(MISC 等非日期目录内容、被弃条目、降级弃单)
    // 由既有逐对象路径补齐 —— 断点续传语义天然复用:循环只问缓存里
    // 还没有的。
    final gaps = [
      for (final h in pending)
        if (!_byHandle.containsKey(h)) h,
    ];
    loaded = ordered.length - gaps.length;
    if (gaps.length < pending.length) {
      // 分页/兜底确有产出:先广播一次「批量已到、缺口未补」的快照。
      _publish(loaded, ordered.length, complete: false);
    }
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
    // 评级同步:0x9434 批量位一发拿全卡「有无星」(SnapBridge 同款
    // 通道,NEF 也在内),有星的适用格式再逐张 0x9803 拉档位 ——
    // 无星的绝大多数对象零事务(不 await,不挡本 Future)。
    unawaited(_syncRatingsViaMeta(generation));
  }

  /// 评级主同步路:0x9434 位图 → 逐张档位补拉。起步延 500ms(枚举沿
  /// UI 先落定,事件窗/测试断言窗口不被闯入);失败(拒答/链路/解析)
  /// 回退旧逐张全量补读([_fillRatingsInBackground])。
  Future<void> _syncRatingsViaMeta(int generation) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      final metas = await session.getObjectsMetaData();
      if (generation != _generation) return;
      for (final m in metas) {
        if (m.hasRating) _metaRated.add(m.handle);
      }
    } on Object {
      AppLog.w(AppLog.browser, '0x9434 评级位图失败,回退逐张补读');
      await _fillRatingsInBackground(generation);
      return;
    }
    _ratingsSeen = true;
    _scheduleRatingPublish();
    for (final handle in _metaRated.toList(growable: false)) {
      if (generation != _generation) return;
      final entry = _byHandle[handle];
      if (entry == null) continue; // 句柄已不在册(被删等)
      if ((_ratings[handle] ?? 0) > 0) continue; // 档位已知(收割/写回)
      // 一律先试 0xDC8A(适用格式 OK);拒答(NEF 形态)由 _fetchRating
      // 内部落 XMP 头读兜底,再不行才「已评级·未知」。非 force:登记
      // 已问集,后续 requestRating 不重复发。
      await _fetchRating(handle);
      if (generation != _generation) return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    // 删除候选甄别(位图外):图像走头 256KB XMP(Rating=-1 = 垃圾桶,
    // 0 = 无评级);视频走容器 NCTG(评级 u16,0xFFFF = 删除候选 ——
    // 位图不标、0xDC8A 读 0,容器是唯一通道)。已拉过档位的(位图有
    // 星)不再读;张间 100ms(图像一笔 256KB / 视频 ~10 笔小读)。
    for (final entry in _byHandle.values.toList(growable: false)) {
      if (generation != _generation) return;
      if (entry.isFolder) continue;
      if (_metaRated.contains(entry.handle)) continue;
      if (entry.kind == ObjectKind.video) {
        await _detectTrashViaNctg(entry);
        if (generation != _generation) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      if (entry.kind != ObjectKind.image) continue;
      if (_trashProbed.contains(entry.handle)) continue;
      await _detectTrashViaXmp(entry.handle);
      if (generation != _generation) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _scheduleRatingPublish();
  }

  /// 删除候选甄别单张:头 256KB XMP 包 Rating 值 —— **-1 = 删除候选**
  /// (真机复标实证:未评分 0、标垃圾桶后变 -1);0 = 无评级;1-5 =
  /// 星档(顺手收);无元素 = 不可判,保持无评级态。
  Future<void> _detectTrashViaXmp(int handle) async {    if (!_trashProbed.add(handle)) return;
    if (!_ratingInFlight.add(handle)) return;
    final gen = _generation;
    try {
      final head = await session.getPartialObject(handle, 0, 262144);
      if (gen != _generation) return;
      final text = String.fromCharCodes(head);
      if (!text.contains('<x:xmpmeta')) return; // 头里无 XMP 包:不作判
      final match = _xmpRatingPattern.firstMatch(text);
      if (match == null) return; // 无 Rating 元素:不可判
      final value = int.tryParse(match.group(1)!) ?? 0;
      if (value < 0) {
        _trashMarked.add(handle); // -1 = 删除候选
        _ratingsSeen = true;
        _scheduleRatingPublish();
      } else if (value >= 1) {
        _ratings[handle] = value; // 位图外但文件里有星(顺手收)
        _ratingsSeen = true;
        _scheduleRatingPublish();
      }
      // 0 = 无评级:甄别已落账即可
    } on Object {
      // 头读失败:静默(保持无评级态)
    } finally {
      _ratingInFlight.remove(handle);
    }
  }

  /// 视频删除候选甄别:容器 NCTG 评级提取(见 media/video_rating.dart)
  /// —— 0xFFFF = 删除候选;1-5 = 星档(位图外顺手收);0/null = 无评级。
  /// 每视频 ~12 笔小读(顶层/moov/udta 箱头 + udta 头 1KB),预算内
  /// 有限步,失败静默不误判。
  Future<void> _detectTrashViaNctg(ObjectEntry entry) async {
    if (!_trashProbed.add(entry.handle)) return;
    if (!_ratingInFlight.add(entry.handle)) return;
    final gen = _generation;
    try {
      final size = entry.sizeInBytes;
      final rating = await readVideoRating((off, len) async {
        if (off >= size) return null;
        return session.getPartialObject(
            entry.handle, off, len.clamp(0, size - off));
      });
      if (gen != _generation) return;
      if (rating == null) return; // 不可判:保持无评级
      _ratingsSeen = true;
      if (rating == 0xffff) {
        _trashMarked.add(entry.handle);
      } else if (rating >= 1) {
        _ratings[entry.handle] = rating; // 位图外但容器里有星(顺手收)
      }
      _scheduleRatingPublish();
    } on Object {
      // 读失败:静默(保持无评级态)
    } finally {
      _ratingInFlight.remove(entry.handle);
    }
  }

  /// 改评(组粒度,0 = 清除):只写**评级适用格式成员**(JPEG/HEIF/
  /// 视频,见 [isRatingCapable])的 0xDC8A —— 真机定案(2026-10-22 Zf
  /// 双链)NEF(0x3000)读写均被相机拒(0xA801/0xA80A,§6.6.3.3 适用
  /// 表本就不含),撞了也是白撞;相机侧评级按文件存,组的星级展示取
  /// 成员最大值。无适用成员(纯 RAW 组)直接报错(相机 API 层不可能
  /// 成功)。乐观上屏(先写缓存即发布),失败整组回滚重发布再上抛;
  /// 成功后读回(0x9803)对齐相机取整口径。
  @override
  Future<void> rateGroup(PhotoGroup group, int stars) async {
    final targets = <int>{
      for (final m in group.members)
        if (isRatingCapable(m)) m.handle, // JPEG/HEIF/视频;NEF 无评级 API
    };
    if (targets.isEmpty) {
      throw StateError(
          '评级仅支持 JPEG/HEIF/视频(该组无可评级成员;NEF 机身可评但 API 不开放): '
          '${group.name}');
    }
    final before = {for (final m in group.members) m.handle: _ratings[m.handle]};
    _applyRating(targets, stars); // 乐观上屏只动 JPG 目标(NEF 无评级能力,不覆写)
    if (_loading == null) {
      _publish(_byHandle.length, _byHandle.length, complete: true);
    }
    final raw = starsToRatingRaw(stars);
    final data = ByteWriter()..u16(raw);
    Object? failure;
    for (final handle in targets) {
      try {
        await session.setObjectPropValue(
            handle, PtpObjectPropCode.rating, data.takeBytes());
        _ratings[handle] = stars;
        _ratingQueried.add(handle);
      } on Exception catch (e) {
        failure = e;
        break;
      }
    }
    if (failure != null) {
      // 整组回滚到写前值(只动本组成员,别组评级不动)。
      final beforeDesc =
          before.entries.map((e) => '${e.key.toRadixString(16)}:${e.value}').join(' ');
      AppLog.w(AppLog.browser,
          '改评失败回滚 ${group.name} ★$stars(写前 $beforeDesc): $failure');
      for (final m in group.members) {
        final previous = before[m.handle];
        if (previous != null) {
          _ratings[m.handle] = previous;
        } else {
          _ratings.remove(m.handle);
        }
      }
      if (_loading == null) {
        _publish(_byHandle.length, _byHandle.length, complete: true);
      }
      throw failure;
    }
    // 读回对齐(相机取整 60→50 同款语义,读值以相机为准);失败不回滚
    // —— OK 应答已是承诺,读回只是锦上添花。
    try {
      final value = await session
          .getObjectPropValue(targets.first, PtpObjectPropCode.rating);
      if (value.length >= 2) {
        _ratings[targets.first] = ratingRawToStars(ByteReader(value).u16());
      }
    } on Exception {
      // 读回失败不挡:按写入值展示
    }
    _ratingsSeen = true;
    _metaRated.addAll(targets); // 写沿即有星(位图本地对表)
    _ratedUnknown.removeAll(targets);
    if (_loading == null) {
      _publish(_byHandle.length, _byHandle.length, complete: true);
    }
  }

  /// 评级缓存改写(乐观上屏沿;0 = 清除;只动发写目标)。
  void _applyRating(Set<int> handles, int stars) {
    for (final handle in handles) {
      if (stars >= 1) {
        _ratings[handle] = stars;
      } else {
        _ratings.remove(handle);
      }
    }
  }

  /// 分页快路页间让路窗(见 _loadAll 页循环)。
  static const Duration pageGap = Duration(milliseconds: 150);

  /// 0x9805 批量属性合并入缓存:仅收 [handleSet] 内句柄(句柄只能来自
  /// GetObjectHandles)、无名/无格式条目弃单、已在册
  /// 跳过(断点续传),返回本次新增的 entry(页发现与进度计数用)。
  /// 评级属性(0xDC8A)独立收割 —— 全属性应答里它是普通成员,条目
  /// 已在册(断点续传)也不丢星。
  List<ObjectEntry> _absorbProps(
      List<PtpObjectProp> props, Set<int> handleSet) {
    _absorbRatings(props);
    final byHandle = <int, List<PtpObjectProp>>{};
    for (final p in props) {
      if (!handleSet.contains(p.handle)) continue;
      byHandle.putIfAbsent(p.handle, () => []).add(p);
    }
    final added = <ObjectEntry>[];
    for (final e in byHandle.entries) {
      if (_byHandle.containsKey(e.key)) continue;
      final entry = ObjectRepository.toEntryFromProps(e.key, e.value);
      if (entry != null) {
        _byHandle[e.key] = entry;
        added.add(entry);
      }
    }
    return added;
  }

  /// 批量应答里的评级条目入缓存(0xDC8A 值 = u16 原始档);入已问集
  ///(数据已在,后台补读不重复拉)。
  void _absorbRatings(List<PtpObjectProp> props) {
    for (final p in props) {
      if (p.code != PtpObjectPropCode.rating) continue;
      final value = p.value;
      if (value is! int) continue;
      _ratings[p.handle] = ratingRawToStars(value);
      _ratingQueried.add(p.handle);
      _ratingsSeen = true;
    }
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
