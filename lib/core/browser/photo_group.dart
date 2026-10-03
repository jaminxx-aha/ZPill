/// 相册条目:一次快门产出的「一张照片」。
///
/// RAW+JPG 双格式(或双卡槽备份副本)对应多个文件,浏览层把它们合并成
/// 一个条目,不再重复显示;选中/下载以组为单位 —— 选一张 = JPG 和 RAW
/// 都拿回。视频不存在双格式,恒为单文件组。
///
/// 配对规则见 [buildPhotoGroups]。
library;

import '../ptpip/object_format.dart';
import 'object_entry.dart';

final class PhotoGroup {
  PhotoGroup(Iterable<ObjectEntry> entries)
      : members = List.unmodifiable(entries) {
    assert(members.isNotEmpty, '相册条目至少含一个文件');
  }

  /// 组成的文件(RAW/JPG 各一;双槽备份可能有同格式副本,字节相同)。
  final List<ObjectEntry> members;

  /// 组内首个 JPG(备份副本等价,任取其一)。
  late final ObjectEntry? jpg = _firstWhere(_isJpg);

  /// 组内首个 RAW(NEF/NRW)。
  late final ObjectEntry? raw = _firstWhere(_isRaw);

  bool get hasJpg => jpg != null;
  bool get hasRaw => raw != null;

  /// 展示代表文件:优先 JPG(缩略图/预览走标准 JPEG 通路最稳,文件名也
  /// 更贴近用户熟悉的成片);无 JPG 用首成员(单 RAW/视频)。
  ObjectEntry get primary => jpg ?? members.first;

  /// 组身份键:成员最大句柄。
  ///
  /// 渐进枚举按句柄倒序(新→旧)填充,组内首个到达的成员必是最大句柄,
  /// 后到成员只会更小 —— 键在配对完成前后稳定(选中态/cell 复用不漂移);
  /// 单文件组即自身句柄,与合并前的旧行为一致。
  late final int key =
      members.reduce((a, b) => a.handle > b.handle ? a : b).handle;

  /// 显示名(代表文件名)。
  String get name => primary.name;

  /// 拍摄时间(同组文件同刻;取代表)。
  DateTime? get capturedAt => primary.capturedAt;

  /// 组内文件字节数合计(下载体量口径)。
  int get totalBytes =>
      members.fold(0, (sum, entry) => sum + entry.sizeInBytes);

  /// 组内文件涉及的文件夹句柄(双槽 RAW/JPG 分存时多于一个;
  /// 这些文件夹相册各计入本组一次)。
  late final Set<int> folderHandles =
      members.map((entry) => entry.parentHandle).toSet();

  bool get isVideo => primary.kind == ObjectKind.video;

  /// 缩略图类型角标:双格式 'jpg+raw',纯 RAW 'raw',纯 JPG 'jpg';
  /// 其他图像格式与视频无角标(视频由摄像机图标表达)。
  String get typeLabel {
    if (isVideo) return '';
    if (hasRaw && hasJpg) return 'jpg+raw';
    if (hasRaw) return 'raw';
    if (hasJpg) return 'jpg';
    return '';
  }

  ObjectEntry? _firstWhere(bool Function(ObjectEntry) test) {
    for (final entry in members) {
      if (test(entry)) return entry;
    }
    return null;
  }

  /// JPG 判定:EXIF/JFIF 格式码,或 .jpg/.jpeg/.jpe 扩展名兜底。
  static bool _isJpg(ObjectEntry entry) {
    final code = entry.formatCode;
    if (code == ObjectFormatCode.exifJpeg || code == ObjectFormatCode.jfif) {
      return true;
    }
    return _hasExt(entry.name, const {'jpg', 'jpeg', 'jpe'});
  }

  /// RAW 判定:尼康 NEF/NRW 扩展名(NEF 格式码 0x3000,只能靠文件名)。
  static bool _isRaw(ObjectEntry entry) =>
      _hasExt(entry.name, const {'nef', 'nrw'});

  static bool _hasExt(String name, Set<String> exts) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot + 1 >= name.length) return false;
    return exts.contains(name.substring(dot + 1).toLowerCase());
  }
}

/// 跨文件夹配对时间窗:同基名跨文件夹(双槽 RAW/JPG 分存)须拍摄时刻
/// 差在此窗内才并组 —— 连拍时 NEF 缓冲落盘可比 JPG 晚数十秒,窗要罩住;
/// 换卡重编号的同名照片(时刻差小时/天级)被它挡在门外。
const Duration kCrossFolderPairWindow = Duration(minutes: 10);

/// 孪生句柄掩码:Zf 句柄 = 槽基址 << 24 | 对象号,同快门两份跨槽共享
/// 低 24 位(2026-10-02 探针对拍实测:0x291A9827 JPG ↔ 0x0A1A9827 NEF)。
const int _kTwinHandleMask = 0xFFFFFF;

/// 文件基名(去扩展名):`DSC_0001.NEF` → `DSC_0001`。RAW/JPG 孪生同基名。
String baseNameOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 把枚举到的对象文件聚成相册条目(RAW+JPG 合并)。
///
/// 两遍成组(2026-10-03 真机反馈修订:旧版要求两份拍摄时刻**同秒**,
/// 连拍落盘时序会让两份差 1 秒以上,同夹也漏并):
/// 1. **同文件夹同基名 → 无条件并**。DCF 规定文件夹内基名唯一,
///    `DSC_0001.NEF` 与 `DSC_0001.JPG` 必属同一次快门,无需看时间。
/// 2. **跨文件夹同基名 → 佐证通过才并**(双槽 RAW/JPG 分存,两夹同名
///    100NIKON):拍摄时刻齐全且差 ≤ [kCrossFolderPairWindow] 判为同拍;
///    任一时刻缺失退回孪生句柄判定(低 24 位共享)。换卡重编号的同名
///    照片时刻差远超窗且不共享低位,不会误并。
///
/// 视频无双格式,自然单文件成组。渐进枚举每块用累积缓存全量重建,结果
/// 只增不漂移([PhotoGroup.key] 取成员最大句柄)。
List<PhotoGroup> buildPhotoGroups(Iterable<ObjectEntry> entries) {
  // 第一遍:文件夹内按 (parentHandle, 基名) 成组 —— 无条件合并。
  final byFolderBase = <String, List<ObjectEntry>>{};
  for (final entry in entries) {
    byFolderBase
        .putIfAbsent(
            '${entry.parentHandle}\u0000${baseNameOf(entry.name)}', () => [])
        .add(entry);
  }
  final folderGroups = <PhotoGroup>[
    for (final members in byFolderBase.values) PhotoGroup(members),
  ];

  // 第二遍:同基名的跨夹组贪心聚类 —— 与簇内任一组佐证通过即并入
  //(簇随并入长大,槽 1 / 槽 2 / 回绕第三夹的链式三组也能归一)。
  final byBase = <String, List<PhotoGroup>>{};
  for (final group in folderGroups) {
    byBase
        .putIfAbsent(baseNameOf(group.members.first.name), () => [])
        .add(group);
  }
  final groups = <PhotoGroup>[];
  for (final candidates in byBase.values) {
    if (candidates.length == 1) {
      groups.add(candidates.single);
      continue;
    }
    final clusters = <List<PhotoGroup>>[];
    for (final group in candidates) {
      var matched = false;
      for (final cluster in clusters) {
        if (cluster.any((c) => _groupsCorroborate(c, group))) {
          cluster.add(group);
          matched = true;
          break;
        }
      }
      if (!matched) clusters.add([group]);
    }
    for (final cluster in clusters) {
      groups.add(cluster.length == 1
          ? cluster.single
          : PhotoGroup([for (final g in cluster) ...g.members]));
    }
  }
  return groups;
}

/// 两组间任一文件对佐证通过即视为同拍。
bool _groupsCorroborate(PhotoGroup a, PhotoGroup b) =>
    a.members.any((x) => b.members.any((y) => _pairCorroborated(x, y)));

/// 跨夹同基名两文件是否同一次快门:时刻齐全只看时间窗(重编号旧照即使
/// 偶然共享低位也不并);任一缺失退回孪生句柄(低 24 位)。
bool _pairCorroborated(ObjectEntry a, ObjectEntry b) {
  final at = a.capturedAt;
  final bt = b.capturedAt;
  if (at != null && bt != null) {
    return at.difference(bt).abs() <= kCrossFolderPairWindow;
  }
  return (a.handle & _kTwinHandleMask) == (b.handle & _kTwinHandleMask);
}
