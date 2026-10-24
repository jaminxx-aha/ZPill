/// 相册条目:一次快门产出的「一张照片」。
///
/// RAW+JPG 双格式(或双卡槽备份副本)对应多个文件,浏览层把它们合并成
/// 一个条目,不再重复显示;下载以组为单位,双格式组由用户选格式
/// (见 [PhotoDownloadFormat]),缺所选格式的组跳过。视频不存在双格式;
/// 同基名 JPG+MOV 双件(运动照片)按实况对处理([PhotoGroup.isMotionPair])。
///
/// 配对规则见 [buildPhotoGroups]。
library;

import '../ptpip/object_format.dart';
import 'object_entry.dart';

/// 下载格式选择(双格式照片组与照片视频混选批次用)。
enum PhotoDownloadFormat {
  /// 仅 JPG:组内没有 JPG → 该组跳过。
  jpg('fmt.jpgOnly', 'fmt.shortJpg'),

  /// 仅 RAW:组内没有 RAW → 该组跳过。
  raw('fmt.rawOnly', 'fmt.shortRaw'),

  /// JPG + RAW:有什么下什么(缺哪个格式就只下另一个)。
  both('fmt.jpgAndRaw', 'fmt.shortJpgRaw'),

  /// 仅视频:视频组全量;照片组只取视频件(实况对),无视频件跳过。
  video('fmt.videoOnly', 'common.video');

  const PhotoDownloadFormat(this.label, this.short);

  /// 选择面板选项文案 = t() 键。
  final String label;

  /// 提示文案简写 = t() 键。
  final String short;
}

final class PhotoGroup {
  PhotoGroup(Iterable<ObjectEntry> entries)
      : members = List.unmodifiable(entries) {
    assert(members.isNotEmpty, '相册条目至少含一个文件');
  }

  /// 组成的文件(RAW/JPG 各一;双槽备份可能有同格式副本,字节相同)。
  final List<ObjectEntry> members;

  /// 组内首个 JPG(备份副本等价,任取其一)。
  late final ObjectEntry? jpg = _firstWhere(isJpgFile);

  /// 组内首个 RAW(NEF/NRW)。
  late final ObjectEntry? raw = _firstWhere(isRawFile);

  /// 组内首个视频成员(同基名 MOV/MP4 与 JPG 同组 = 运动照片双件
  /// 形态;尼康运动照片常态是单 JPG 内嵌视频,拆分见
  /// core/media/motion_photo.dart,双件形态待真机核对)。
  late final ObjectEntry? movie = _firstWhere(isVideoFile);

  bool get hasJpg => jpg != null;
  bool get hasRaw => raw != null;

  /// 实况照片对:静帧 JPG + 独立视频件同组(同文件夹同基名第一遍
  /// 配对必并组);下载时两者配对导入为一张实况(见传输引擎收尾)。
  bool get isMotionPair => hasJpg && movie != null;

  /// 展示代表文件:优先 JPG(缩略图/预览走标准 JPEG 通路最稳,文件名也
  /// 更贴近用户熟悉的成片);无 JPG 用首成员(单 RAW/视频)。
  ObjectEntry get primary => jpg ?? members.first;

  /// 组内不同基名数:RAW+JPG 孪生与双槽备份副本恒 1;≥2 = 连拍簇
  ///(多张独立快门并成一条目,见 buildPhotoGroups 第三遍)。
  late final int shotCount =
      members.map((entry) => baseNameOf(entry.name)).toSet().length;

  /// 连拍簇:一次快门序列的多张并成一条目(视频不参与连拍并组)。
  bool get isBurst => !isVideo && shotCount > 1;

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
  /// 实况对追加 '+mov';连拍簇追加 '×N'(如 'jpg ×3');其他图像格式
  /// 与视频无角标。
  String get typeLabel {
    if (isVideo) return '';
    final base = switch ((hasRaw, hasJpg)) {
      (true, true) => 'jpg+raw',
      (true, false) => 'raw',
      (false, true) => 'jpg',
      (false, false) => '',
    };
    final live = isMotionPair ? '+mov' : '';
    if (isBurst) {
      return base.isEmpty ? '×$shotCount' : '$base$live ×$shotCount';
    }
    return '$base$live';
  }

  /// 按格式选择取下载文件。
  ///
  /// 视频组不受格式选择影响恒全量;实况对的视频件跟随静帧(选「仅 JPG」
  /// 也带上 —— 它是这张照片的实况成分,不是另一张);[PhotoDownloadFormat
  /// .jpg]/[raw] 同格式**按基名去重**取文件 —— 双槽备份副本(同基名)
  /// 只取一份,连拍簇(每张各基名)每张各一份;组内缺该格式返回空列表
  ///(调用方据此跳过)。「仅视频」照片组只取视频件 —— 实况对下视频侧,
  /// 纯照片组空列表跳过。
  List<ObjectEntry> membersFor(PhotoDownloadFormat format) {
    if (isVideo) return members;
    return switch (format) {
      PhotoDownloadFormat.jpg => [
          ..._onePerBaseName(isJpgFile),
          ...members.where(isVideoFile),
        ],
      PhotoDownloadFormat.raw => _onePerBaseName(isRawFile),
      PhotoDownloadFormat.both => members,
      PhotoDownloadFormat.video => [
          for (final entry in members)
            if (isVideoFile(entry)) entry,
        ],
    };
  }

  /// 同格式文件按基名去重(备份副本等价,任取其一)。
  List<ObjectEntry> _onePerBaseName(bool Function(ObjectEntry) test) {
    final seen = <String>{};
    final out = <ObjectEntry>[];
    for (final entry in members) {
      if (test(entry) && seen.add(baseNameOf(entry.name))) {
        out.add(entry);
      }
    }
    return out;
  }

  ObjectEntry? _firstWhere(bool Function(ObjectEntry) test) {
    for (final entry in members) {
      if (test(entry)) return entry;
    }
    return null;
  }
}

bool _hasExt(String name, Set<String> exts) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= name.length) return false;
  return exts.contains(name.substring(dot + 1).toLowerCase());
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

/// JPG 判定:EXIF/JFIF 格式码,或 .jpg/.jpeg/.jpe 扩展名兜底。
bool isJpgFile(ObjectEntry entry) {
  final code = entry.formatCode;
  if (code == ObjectFormatCode.exifJpeg || code == ObjectFormatCode.jfif) {
    return true;
  }
  return isJpgFilename(entry.name);
}

/// RAW 判定:尼康 NEF/NRW 扩展名(NEF 格式码 0x3000,只能靠文件名)。
bool isRawFile(ObjectEntry entry) => isRawFilename(entry.name);

/// 评级适用格式(官方 §6.6.3.3):0x3800 Unknown Image / 0x3801 EXIF/
/// JPEG / 0x300D MOV / 0x380D TIFF / 0xB200 HEIF / 0xB982 MP4。
/// NEF(0x3000 Undefined)**不在表** —— 真机实证(2026-10-22 Zf 双链)
/// API 读写均拒(0xA801/0xA80A),虽然机身 UI 可评 NEF(固件 API 落差,
/// NEF 的星级 App 侧摸不到)。
const Set<int> kRatingCapableFormats = {
  0x3800,
  ObjectFormatCode.exifJpeg,
  ObjectFormatCode.quickTime,
  ObjectFormatCode.tiff,
  ObjectFormatCode.heif,
  ObjectFormatCode.mp4,
};

/// 评级能力判定(读/写/补读的目标门):格式码在适用表为准;码缺失
///(异常形态)退扩展名兜底(非 RAW 即试 —— 相机会以拒答回答)。
bool isRatingCapable(ObjectEntry entry) {
  final code = entry.formatCode;
  if (code != null) return kRatingCapableFormats.contains(code);
  return !isRawFile(entry);
}

/// 视频文件判定:PTP 格式码(QuickTime/MPEG)或 .mov/.mp4 扩展名兜底。
bool isVideoFile(ObjectEntry entry) {
  if (entry.kind == ObjectKind.video) return true;
  return isVideoFilename(entry.name);
}

/// 文件名级格式判定:本地图库过滤等没有 [ObjectEntry] 的场景按名分流,
/// 扩展名集合与条目级判定同源,别处分叉会两边口径不一。
bool isJpgFilename(String name) => _hasExt(name, const {'jpg', 'jpeg', 'jpe'});

/// 通用筛选格式档(相机相册/图库筛选弹层共用,设计同评级子面板):
/// 相机产出的五族文件。label 为拉丁短名,t() 未命中原文直传。
enum MediaFormat {
  nef('NEF'),
  jpg('JPG'),
  mov('MOV'),
  mp4('MP4'),
  hif('HIF');

  const MediaFormat(this.label);

  final String label;
}

/// 扩展名 → 格式档(未知扩展返回 null —— 全档直通,选中态不含它)。
/// NEF 码 0x3000(undefined)无判别力,DCF 扩展名即真相,相机侧同用此映射。
MediaFormat? mediaFormatOfFilename(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'nef' || 'nrw' => MediaFormat.nef,
    'jpg' || 'jpeg' => MediaFormat.jpg,
    'mov' || 'm4v' => MediaFormat.mov,
    'mp4' => MediaFormat.mp4,
    'hif' || 'heif' => MediaFormat.hif,
    _ => null,
  };
}

bool isRawFilename(String name) => _hasExt(name, const {'nef', 'nrw'});

bool isVideoFilename(String name) => _hasExt(name, const {'mov', 'mp4', 'm4v'});

/// 连拍相邻张间隔窗:同一夹内相邻快门差 ≤ 此值才归连拍段
///(Zf 高速连拍 ~14fps ≈ 71ms、低速 ~5fps ≈ 200ms,500ms 罩住两档,
/// 又排除有意逐张补拍)。
const Duration kBurstShotGap = Duration(milliseconds: 500);

/// 连拍成段最少张数:不足此数的短序列不并(偶发两连拍保持独立)。
const int kBurstMinShots = 3;

/// 把枚举到的对象文件聚成相册条目(RAW+JPG 合并 + 连拍簇合并)。
///
/// 三遍成组(2026-10-03 真机反馈修订:旧版要求两份拍摄时刻**同秒**,
/// 连拍落盘时序会让两份差 1 秒以上,同夹也漏并):
/// 1. **同文件夹同基名 → 无条件并**。DCF 规定文件夹内基名唯一,
///    `DSC_0001.NEF` 与 `DSC_0001.JPG` 必属同一次快门,无需看时间。
/// 2. **跨文件夹同基名 → 佐证通过才并**(双槽 RAW/JPG 分存,两夹同名
///    100NIKON):拍摄时刻齐全且差 ≤ [kCrossFolderPairWindow] 判为同拍;
///    任一时刻缺失退回孪生句柄判定(低 24 位共享)。换卡重编号的同名
///    照片时刻差远超窗且不共享低位,不会误并。
/// 3. **连拍段聚类**:同一文件夹内、相邻条目拍摄时刻差 ≤ [kBurstShotGap]
///    的连续段,段长 ≥ [kBurstMinShots] 并成一个连拍簇([PhotoGroup.isBurst])。
///    双格式组以整组入段;时刻缺失/视频不参与。
///
/// 渐进枚举每块用累积缓存全量重建,结果只增不漂移([PhotoGroup.key]
/// 取成员最大句柄 —— 倒序填充下簇内首到的必是最大句柄,后到只更小)。
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
  return _mergeBursts(groups);
}

/// 第三遍:连拍段聚类(见 buildPhotoGroups 注 3)。
///
/// 按代表文件所在夹分桶、拍摄时刻排序后线性扫描分段;段长达标的多组
/// 并一簇,不足的保持原组。无时刻条目与视频无法判段,保持独立。
List<PhotoGroup> _mergeBursts(List<PhotoGroup> groups) {
  final byFolder = <int, List<PhotoGroup>>{};
  final skipped = <PhotoGroup>[];
  for (final group in groups) {
    if (group.isVideo || group.capturedAt == null) {
      skipped.add(group);
      continue;
    }
    byFolder.putIfAbsent(group.primary.parentHandle, () => []).add(group);
  }
  final out = <PhotoGroup>[...skipped];
  for (final folderGroups in byFolder.values) {
    folderGroups.sort((a, b) {
      final t = a.capturedAt!.compareTo(b.capturedAt!);
      return t != 0 ? t : a.key.compareTo(b.key);
    });
    var start = 0;
    for (var i = 1; i <= folderGroups.length; i++) {
      final inGap = i < folderGroups.length &&
          folderGroups[i]
                  .capturedAt!
                  .difference(folderGroups[i - 1].capturedAt!) <=
              kBurstShotGap;
      if (!inGap) {
        final run = folderGroups.sublist(start, i);
        if (run.length >= kBurstMinShots) {
          out.add(PhotoGroup([for (final g in run) ...g.members]));
        } else {
          out.addAll(run);
        }
        start = i;
      }
    }
  }
  return out;
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
