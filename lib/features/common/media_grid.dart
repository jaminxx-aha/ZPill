/// 相机相册与图库两页共用的网格基础件:日期分段与段头、格骨架(手势 +
/// 附加角标 + 多选覆盖)、无底角标(格式/评级/时长,白字投影)、筛选弹层
/// 骨架(tune 锚 + 收紧行高/分区头/勾位)+ 评级级联子面板(iOS 相册式
/// 多选并集)。页面专有件(缩略取数管线、下载/删除、排序、连拍聚合、
/// 预取)留在各自页面 —— 见各页库头注。
library;

import 'package:flutter/material.dart';

import 'sort_bars_icon.dart';
import '../../design/app_dimens.dart';
import '../../core/browser/album.dart';
import '../../core/browser/photo_group.dart';
import '../../l10n/l10n.dart';
import 'format.dart';
import 'rating_filter.dart';
import 'trash_rating_icon.dart';

// ── 日期分段 ─────────────────────────────────────────────────────────

/// 网格日期段:同日条目一段([day] null = 未知日期,收尾)。[firstIndex]
/// 记段首在全局列表的下标(查看器按全局序翻页)。
final class MediaDateSection<T> {
  MediaDateSection(this.day, this.items);

  final DateTime? day;
  final List<T> items;

  int firstIndex = 0;
}

/// items 按给定时刻分段:相邻同日归一段(null 时刻条目归「未知日期」段
/// 收尾);段序随输入序(相机相册 = 仓库倒序,图库 = 排序后列表)。
List<MediaDateSection<T>> groupMediaByDate<T>(
    List<T> items, DateTime? Function(T) capturedAt) {
  final dated = <MediaDateSection<T>>[];
  final undated = <T>[];
  MediaDateSection<T>? current;
  for (final item in items) {
    final at = capturedAt(item);
    if (at == null) {
      undated.add(item);
      continue;
    }
    final local = at.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (current != null && current.day == day) {
      current.items.add(item);
    } else {
      current = MediaDateSection(day, [item]);
      dated.add(current);
    }
  }
  final sections = dated;
  if (undated.isNotEmpty) {
    sections.add(MediaDateSection(null, undated));
  }
  var offset = 0;
  for (final s in sections) {
    s.firstIndex = offset;
    offset += s.items.length;
  }
  return sections;
}

/// 段头:日期 + 张数;多选模式下点按整日选择/取消([selecting] 且
/// [onToggle] 非空才可点),右侧显示该日是否已全选。
class MediaSectionHeader extends StatelessWidget {
  const MediaSectionHeader({
    super.key,
    required this.day,
    required this.count,
    this.selecting = false,
    this.daySelected = false,
    this.onToggle,
  });

  final DateTime? day;
  final int count;
  final bool selecting;
  final bool daySelected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    // 日期段(sectionDateLabel)为键+参记录,与「未知日期」一并经 tm()
    // 落地;'· N 张' 尾段在 grid.sectionHeader 模板里。
    final label = context.tm(day == null
        ? (key: 'grid.undated', args: null)
        : sectionDateLabel(day!));
    return InkWell(
      onTap: selecting && onToggle != null ? onToggle : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.t('grid.sectionHeader', {'label': label, 'n': count}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (selecting)
              Icon(
                daySelected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: daySelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

// ── 格 ───────────────────────────────────────────────────────────────

/// 网格格子骨架:手势([key] 定位锚/点按/长按)包 Stack —— 缩略内容
/// 铺满 + 附加角标([badges],Align 自带定位)+
/// 多选覆盖(压暗 + 右上勾圈)。两页同款;缩略内容页自拟(取数管线
/// 各异:相机 0x100A 缓存小图 / 图库双源小档)。
class MediaGridCell extends StatelessWidget {
  const MediaGridCell({
    super.key,
    required this.child,
    this.badges = const [],
    this.selecting = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;

  final List<Widget> badges;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // 角标文字钉标准字号:徽标是图标+文字的耦合组件,不跟动态字号
      // 缩(textScaler 缩 Text 不缩 Icon —— iOS 系统字号偏离标准时
      // 格内文字与星形比例失配,ohos 恒 1.0 无此症,2026-10-24 实测)。
      child: MediaQuery.withNoTextScaling(
        child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          ...badges,
          if (selecting)
            Positioned.fill(
              child: ColoredBox(
                color: selected
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.55),
              ),
            ),
          if (selecting)
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                  size: 20,
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}

// ── 评级滤网选集 ─────────────────────────────────────────────────────

/// 评级筛选选集(两页共用状态件):空集 = 全部,非空 = 各分类并集;
/// 「全部」与各分类互斥(iOS 相册 Media Types 式)。页面持有实例,
/// 变更沿自行 setState(并按页面规矩清空网格选中)。
final class RatingFilterSelection {
  final Set<RatingFilter> _values = {};

  /// 是否「全部」(空选集)。
  bool get isAll => _values.isEmpty;

  /// 该档当前是否勾选(「全部」行 = 空选集)。
  bool contains(RatingFilter r) =>
      r.isAll ? _values.isEmpty : _values.contains(r);

  /// 选档:「全部」= 清空(已空则空转);分类 = 勾/取消切换。
  void toggle(RatingFilter r) {
    if (r.isAll) {
      _values.clear();
    } else if (!_values.remove(r)) {
      _values.add(r);
    }
  }

  /// 清空选集(回「全部」;「清除筛选」动作用)。
  void clear() => _values.clear();

  /// 滤网:空选集 = 全放行;[available] 假(评级数据未建立)恒放行
  /// (防把「未取到」当「未评」筛空);非空 = 各分类任一命中即收。
  bool allows({
    required int rating,
    bool trashStar = false,
    bool ratedUnknown = false,
    bool available = true,
  }) =>
      _values.isEmpty ||
      !available ||
      _values.any((r) =>
          r.allows(rating, ratedUnknown: ratedUnknown, trashStar: trashStar));

  /// 当前选中(持久化读出)。
  Iterable<RatingFilter> get values => _values;

  /// 恢复持久化选集(整体替换)。
  void restore(Iterable<RatingFilter> rs) {
    _values
      ..clear()
      ..addAll(rs);
  }
}

// ── 排序 ─────────────────────────────────────────────────────────────

/// 排序键(两页共用):时间 = 拍摄/修改时刻;文件名;文件大小。
enum MediaSortKey { time, name, size }

/// 排序态(两页共用状态件):键 + 方向。默认 = 时间从大到小
///(新→旧,两页既有默认序)。
class MediaSortState {
  MediaSortState({this.key = MediaSortKey.time, this.desc = true});

  MediaSortKey key;

  /// true = 从大到小(时间:新→旧;大小:大→小;文件名:Z→A)。
  bool desc;
}

/// 通用比较:键取值;null 时刻恒排尾(两向同)。返回按方向排好序的副本。
List<T> sortMedia<T>(
  List<T> items,
  MediaSortState sort,
  (DateTime?, String, int) Function(T item) keyOf,
) {
  int cmp(T a, T b) {
    final (ta, na, sa) = keyOf(a);
    final (tb, nb, sb) = keyOf(b);
    final r = switch (sort.key) {
      MediaSortKey.time => switch ((ta, tb)) {
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
          (_, _) => ta!.compareTo(tb!),
        },
      MediaSortKey.name => na.toLowerCase().compareTo(nb.toLowerCase()),
      MediaSortKey.size => sa.compareTo(sb),
    };
    return sort.desc ? -r : r;
  }

  // List.sort 不稳定:同键(如同时刻双格式组)按输入序保序。
  final tagged = [for (var i = 0; i < items.length; i++) (items[i], i)];
  tagged.sort((a, b) {
    final r = cmp(a.$1, b.$1);
    return r != 0 ? r : a.$2 - b.$2;
  });
  return [for (final t in tagged) t.$1];
}

/// 排序分区(两页共用):三行平铺(时间/文件名/文件大小),无二级
/// 面板 —— 点当前键翻方向,点他键切键(方向沿用);当前键行尾示排序
/// 图标(Icons.sort,降序正置/升序旋转 180°,主色),其余 chevron。
/// 选向不收层,点弹层外才收。选向沿回调 [onTap](页面 setState)。
List<Widget> sortMenuSection(
  BuildContext context,
  MediaSortState sort,
  MenuSectionState sections,
  void Function() onChanged,
  void Function(MediaSortKey key) onTap,
) {
  final scheme = Theme.of(context).colorScheme;
  Widget entry(MediaSortKey key, String label) {
    final active = sort.key == key;
    return MenuItemButton(
      key: ValueKey('sort-${key.name}'),
      style: filterMenuChildRowStyle,
      closeOnActivate: false, // 全行不收层,点外才收
      trailingIcon: active
          ? SortBarsIcon(
              desc: sort.desc, size: kMenuIconSize, color: scheme.primary)
          : null,
      onPressed: () => onTap(key),
      child: filterMenuText(context.t(label)),
    );
  }

  return [
    filterMenuSectionHeader(
        context, context.t('libpage.sort'), 'sort', sections, onChanged),
    if (!sections.isCollapsed('sort')) ...[
      entry(MediaSortKey.time, 'libpage.sortTime'),
      entry(MediaSortKey.name, 'libpage.sortName'),
      entry(MediaSortKey.size, 'libpage.sortSize'),
    ],
  ];
}

// ── 显示开关 ─────────────────────────────────────────────────────────

/// 「显示」选集(两页共用状态件):勾选哪项,格上显示哪类角标;
/// 两项独立多选,默认都不显示(净格)。折叠态在 [MenuSectionState]。
final class ShowToggle {
  bool rating = false;
  bool format = false;
}

/// 「显示」分区(与排序/筛选同第一层):无二级面板 —— 两项(评级/
/// 格式)直接列在头行下方,头行点按折叠/展开([ShowToggle.expanded],
/// 默认展开)。两项独立多选,勾选沿回调 [onChanged](页面 setState)。
List<Widget> showMenuSection(
  BuildContext context,
  ShowToggle toggle,
  MenuSectionState sections,
  void Function() onChanged,
) {
  return [
    filterMenuSectionHeader(
        context, context.t('grid.show'), 'show', sections, onChanged),
    if (!sections.isCollapsed('show')) ...[
      MenuItemButton(
        key: const ValueKey('show-rating'),
        style: filterMenuChildRowStyle,
        closeOnActivate: false, // 勾选不收,点外才收
        trailingIcon: filterMenuCheck(context, toggle.rating),
        onPressed: () {
          toggle.rating = !toggle.rating;
          onChanged();
        },
        child: filterMenuText(context.t('grid.rating')),
      ),
      MenuItemButton(
        key: const ValueKey('show-format'),
        style: filterMenuChildRowStyle,
        closeOnActivate: false,
        trailingIcon: filterMenuCheck(context, toggle.format),
        onPressed: () {
          toggle.format = !toggle.format;
          onChanged();
        },
        child: filterMenuText(context.t('grid.formatFilter')),
      ),
    ],
  ];
}

/// 无底角标(去胶囊)的文字/图标投影:白字直接落在照片上,靠投影
/// 保可读性(下偏移 1px + 3px 模糊半透黑,轻而不脏)。
const List<Shadow> kOverlayTextShadows = [
  Shadow(offset: Offset(0, 1), blurRadius: 3, color: Color(0x80000000)),
];

/// 角标文字统一字体(Inter 随包,见 pubspec fonts 注;SF 的 OFL 近似
/// 替身 —— SF 本体专有不可入包):默认字体是平台各自的(iOS=SF/
/// ohos=HarmonyOS Sans),同 fontSize 渲染出的字高/落点有字体级差异
/// —— 角标是跨端要求逐像素一致的组件,显式钉随包字体。星形
/// (MaterialIcons)本就随包两端同形,无需处理。
const String kOverlayFontFamily = 'InterBadge';

/// 角标文字统一样式(白 + 投影 + 随包字体;[size] 10 = 格文字档)。
TextStyle overlayBadgeTextStyle(double size) => TextStyle(
      color: Colors.white,
      fontSize: size,
      height: 1.0,
      fontFamily: kOverlayFontFamily,
      shadows: kOverlayTextShadows,
    );

/// 格左下「显示」角标(无底,白字投影):[format] 格式文案,
/// [extra] 附加文案(连拍 ×N 等 —— 格式关也显,置于格式后),
/// [ratingIcon] 评级图标(见 [ratingInlineIcon]);共存时先文案后图标,
/// 同行包裹;全空不占位。
class ShowChip extends StatelessWidget {
  const ShowChip({super.key, this.format, this.extra, this.ratingIcon});

  /// 格式文案(「显示·格式」勾选时)。
  final String? format;

  /// 附加文案(连拍聚合计数;与格式开关无关)。
  final String? extra;

  /// 评级图标(「显示·评级」勾选时;无自带底框)。
  final Widget? ratingIcon;

  @override
  Widget build(BuildContext context) {
    final hasFormat = format != null && format!.isNotEmpty;
    final hasExtra = extra != null && extra!.isNotEmpty;
    if (!hasFormat && !hasExtra && ratingIcon == null) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          // 居中对齐(用户定稿 2026-10-24):盒底/基线对齐都被字体度量
          // 差异坑过(iOS SF 与 ohos HarmonyOS Sans 的 descent/基线位
          // 不同,端端观感不一);居中只比盒子几何,双端一致。
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (hasFormat) ...[
              Text(format!, style: overlayBadgeTextStyle(10)),
              if (hasExtra || ratingIcon != null) const SizedBox(width: 3),
            ],
            if (hasExtra) ...[
              Text(extra!, style: overlayBadgeTextStyle(10)),
              if (ratingIcon != null) const SizedBox(width: 3),
            ],
            if (ratingIcon != null) ratingIcon!,
          ],
        ),
      ),
    );
  }
}

/// 视频时长角标(格右下,原摄像机角标位):无底白字投影,字号与
/// 「显示」角标的格式文字同大(10);空文案不占位。
class DurationChip extends StatelessWidget {
  const DurationChip({super.key, this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Text(text!, style: overlayBadgeTextStyle(10)),
      ),
    );
  }
}

/// 「显示」评级图标(嵌格式角标行内,无自带底框):删除候选 = 单色
/// 白桶镂空星(镂空透明 —— 无胶囊后照片直接透出);有星 = 单色 ★ +
/// 数(未知档只星);未评级返回 null(无图标)。全部带投影。
Widget? ratingInlineIcon({
  required int stars,
  bool unknown = false,
  bool trash = false,
}) {
  if (trash) {
    return const TrashRatingIcon(
        size: 10,
        color: Colors.white,
        // 镂空星 = 半透黑(与投影同色系):去胶囊后镂空若全透明,星形
        // 直接透出照片,花图上不可辨 —— 弹层行「桶内见星」的观感对齐
        //(彼处镂空透面板底,此处无底,以半透黑代底)。
        holeColor: Color(0x80000000));
  }
  if (stars <= 0 && !unknown) return null;
  return Row(
    mainAxisSize: MainAxisSize.min,
    // 居中对齐(用户定稿),见 ShowChip 注。
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      // 星形与文字统一 10(用户定稿 2026-10-24:图标字号同档)。
      const Icon(Icons.star,
          size: 10, color: Colors.white, shadows: kOverlayTextShadows),
      if (stars > 0) ...[
        const SizedBox(width: 1),
        Text('$stars', style: overlayBadgeTextStyle(10)), // 与格式文字同大
      ],
    ],
  );
}

// ── 格式滤网选集 ─────────────────────────────────────────────────────

/// 格式筛选选集(两页共用状态件,同 [RatingFilterSelection] 语义):
/// 空集 = 全部,非空 = 各格式并集;未知格式(扩展名不属五档)仅在
/// 空选集下显示。
final class FormatFilterSelection {
  final Set<MediaFormat> _values = {};

  /// 是否「全部」(空选集)。
  bool get isAll => _values.isEmpty;

  /// 当前选中格式(空态文案拼接用)。
  Iterable<MediaFormat> get values => _values;

  /// 恢复持久化选集(整体替换)。
  void restore(Iterable<MediaFormat> fs) {
    _values
      ..clear()
      ..addAll(fs);
  }

  bool contains(MediaFormat f) => _values.contains(f);

  void toggle(MediaFormat f) =>
      _values.contains(f) ? _values.remove(f) : _values.add(f);

  void clear() => _values.clear();

  /// 滤网:空选集全放行;非空 = 该格格式在选集中。
  bool allows(MediaFormat? f) =>
      _values.isEmpty || (f != null && _values.contains(f));
}

/// 文件夹筛选选集(相机相册专属,同多选语义):空集 = 全部照片(汇总),
/// 非空 = 各所选文件夹内容并集。
final class FolderFilterSelection {
  final Set<int> _values = {};

  /// 是否「全部照片」(空选集)。
  bool get isAll => _values.isEmpty;

  bool contains(int folderHandle) => _values.contains(folderHandle);

  void toggle(int folderHandle) => _values.contains(folderHandle)
      ? _values.remove(folderHandle)
      : _values.add(folderHandle);

  /// 直加(对账应用持久化选集)。
  void add(int folderHandle) => _values.add(folderHandle);

  void clear() => _values.clear();

  /// 初始选中(入口句柄;汇总句柄 = 空选集)。
  void seed(int folderHandle) {
    if (folderHandle != CameraAlbum.allPhotosHandle) _values.add(folderHandle);
  }
}

// ── 筛选弹层骨架 ─────────────────────────────────────────────────────

/// 筛选弹层锚(AppBar 右上 tune 钮弹出,iPhone 图库式分区卡片):卡片
/// 风格与锚钮两页同款;[children] = 页面自组的分区序列。
class FilterMenu extends StatelessWidget {
  const FilterMenu({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      reservedPadding: const EdgeInsets.symmetric(vertical: 8),
      style: MenuStyle(
        // 右下对齐:面板右缘跟锚钮右缘走(贴边钳制吃掉横向偏移,靠对齐
        // 才有真缝隙)。
        alignment: AlignmentDirectional.bottomEnd,
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      alignmentOffset: const Offset(-12, -2), // 一层弹窗微上移 + 右侧留缝
      menuChildren: children,
      builder: (context, controller, child) => IconButton(
        tooltip: context.t('libpage.filter'),
        onPressed: () {
          if (controller.isOpen) {
            controller.close();
            return;
          }
          // 右对齐 + 右侧留缝:open(position:) 走显式定位路径,不过
          // _positionChild 的贴边钳制(右缘锚定的面板必被钳回贴边,
          // alignmentOffset 在该路径下整个被丢弃)。
          final box = context.findRenderObject()! as RenderBox;
          final anchorLeft = box.localToGlobal(Offset.zero).dx;
          final screenW = MediaQuery.of(context).size.width;
          const panelWidth = kMenuRowWidth; // 实测定标:面板宽 = 行宽(内边距 0,见临时探针实测)
          // 面板右缘钉在屏幕右缘内缩 10 逻辑像素(与系统图库弹层右距
          // 一致;相对屏宽算,不吃锚钮内距误差)。
          controller.open(position: Offset(
            screenW - anchorLeft - 10 - panelWidth,
            box.size.height - 2,
          ));
        },
        icon: const Icon(Icons.tune),
      ),
    );
  }
}

/// 弹层行统一收紧行高(48 → 36):M3 菜单行最小高 48,只改 minimumSize
/// 会被移动端 tapTargetSize=padded 架空(仍 48)—— 须 shrinkWrap 才真
/// 生效;行横 padding 8。两页同款(2026-10-20 三轮真机收口)。
/// 弹层行首/行尾图标统一尺寸(与星档行星同大;一处改全局生效)。
const double kMenuIconSize = 18;

/// 弹层行文字字号(主题默认 14)。
const double kMenuTextSize = 14;

/// 弹层定宽行:宽 × 高。
const double kMenuRowWidth = 156;
const double kMenuRowHeight = 36;

const filterMenuRowStyle = ButtonStyle(
  // 定宽行(156):弹层面板宽恒定,行尾图标位预留,不随勾选/档位变动;
  // 行文案超宽由 [filterMenuText] 省略。
  minimumSize: WidgetStatePropertyAll(Size(kMenuRowWidth, kMenuRowHeight)),
  maximumSize: WidgetStatePropertyAll(Size(kMenuRowWidth, kMenuRowHeight)),
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 8, vertical: 2),
  ),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 分区分割线(一级分区之间,细线随头缩进)。
const menuSectionDivider = Divider(
  height: 9,
  thickness: 0.5,
  indent: 8,
  endIndent: 8,
);

/// 二级行样式(挂一级头下:左缩进 24 分层;定宽/行高/省略同主行)。
const filterMenuChildRowStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(kMenuRowWidth, kMenuRowHeight)),
  maximumSize: WidgetStatePropertyAll(Size(kMenuRowWidth, kMenuRowHeight)),
  padding: WidgetStatePropertyAll(
    EdgeInsets.only(left: 24, right: 8, top: 2, bottom: 2),
  ),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 弹层行文案:单行省略(定宽行溢出保护);字号随主题默认(14)。
Widget filterMenuText(String text) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: kMenuTextSize),
    );

/// 分区折叠态(页面持有):头行点按切换,行随头收展。
/// [section] = 分区名(sort/filter/show/view…页面自定)。
final class MenuSectionState {
  final Set<String> _collapsed = {};

  bool isCollapsed(String section) => _collapsed.contains(section);

  void toggle(String section) => _collapsed.contains(section)
      ? _collapsed.remove(section)
      : _collapsed.add(section);
}

/// 分区头行(可折叠,左右随行对齐):点按切换该分区折叠态,行尾
/// expand_less(展开中)/ expand_more(已折叠)。用户实证分区头有
/// 导航价值,保留 + 升级为折叠开关。
Widget filterMenuSectionHeader(
  BuildContext context,
  String label,
  String section,
  MenuSectionState state,
  void Function() onChanged,
) =>
    MenuItemButton(
      key: ValueKey('section-$section'),
      style: filterMenuRowStyle,
      closeOnActivate: false, // 折叠切换,不收面板
      trailingIcon: Icon(
        state.isCollapsed(section) ? Icons.expand_more : Icons.expand_less,
        size: kMenuIconSize,
      ),
      onPressed: () {
        state.toggle(section);
        onChanged();
      },
      child: filterMenuText(label),
    );

/// 行尾勾位:选中 = 主色,未选 = 透明占位钉宽(多选换选不跳行)。
Widget filterMenuCheck(BuildContext context, bool on) => Icon(
      Icons.check,
      size: kMenuIconSize,
      color: on ? Theme.of(context).colorScheme.primary : Colors.transparent,
    );

/// 评级星档行首的实心星组(N 颗,品牌黄 —— 与网格评级角标同色;
/// 星 18,配合 172 定宽行)。
Widget ratingStarsRow(int n) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          const Icon(Icons.star, size: kMenuIconSize),
      ],
    );

/// 评级筛选分区:级联子菜单入口行(挂在「筛选:」头下,无独立分区头;
/// iOS 相册 Media Types 式 —— 点开子面板与父面板共存,各档选后不收
/// 层,点弹层外任意处才整体收起)。「全部」与各分类互斥(勾全部 = 清空
/// 选集),分类多选并集;「已评级」不设行(NEF 未知档收不进筛选,数据
/// 面照旧);删除候选仅图标,与星档行同素。两页同款;勾选态读
/// [selection],选档沿回调 [onToggle](页面在里面 setState)。
List<Widget> ratingFilterMenuSection(
  BuildContext context,
  RatingFilterSelection selection,
  void Function(RatingFilter r) onToggle,
) {
  final scheme = Theme.of(context).colorScheme;
  return [
    // 级联子面板:独立 [MenuAnchor] 锚在入口行上(与父面板共存)。不用
    // SubmenuButton —— 其嵌套锚的焦点开合(按钮焦点申请落在面板打开之
    // 后,首点即被 _handleFocusChange 收回)在真机上表现为「点开即收,
    // 二点才稳」;独立锚与 tune 锚同一开启机制,无此竞态。
    MenuAnchor(
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd, // 子面板右缘随行,级联内缩
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      // 行序(iOS 相册式):全部 → 删除候选 → 无评级 → ★1-5。行首
      // 图标全档统一 18:删除候选黄桶黑星、无评级黄空心星均仅图标无
      // 文字,与星档行同素(黄 = 品牌色)。
      menuChildren: [
        for (final r in const [
          RatingFilter.all,
          RatingFilter.trash,
          RatingFilter.none,
          RatingFilter.one,
          RatingFilter.two,
          RatingFilter.three,
          RatingFilter.four,
          RatingFilter.five,
        ])
          MenuItemButton(
            key: ValueKey('ratingFilter-${r.index}'),
            style: filterMenuRowStyle,
            closeOnActivate: false, // 选档不收,点外才收
            // 图标颜色与「全部」行一致(主题默认,不另着色;黄桶以
            // IconTheme 色绘制、镂空星透面板底)。
            leadingIcon: switch (r) {
              RatingFilter.none => const Icon(Icons.star_border,
                  size: kMenuIconSize),
              RatingFilter.trash => TrashRatingIcon(
                  size: kMenuIconSize,
                  // 与星档行同色:M3 菜单行首图标 = onSurfaceVariant
                  //(外层 IconTheme 是 onSurface 黑,取内层才同灰)。
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  holeColor: scheme.surfaceContainerLow),
              _ => r == RatingFilter.all
                  ? const Icon(Icons.apps, size: kMenuIconSize)
                  : ratingStarsRow(r.stars),
            },
            trailingIcon: filterMenuCheck(context, selection.contains(r)),
            onPressed: () => onToggle(r),
            child: r.label.isEmpty ||
                    r == RatingFilter.trash ||
                    r == RatingFilter.none
                ? const SizedBox.shrink()
                : filterMenuText(context.t(r.label)),
          ),
      ],
      builder: (context, controller, child) => MenuItemButton(
        key: const ValueKey('ratingFilter-entry'),
        style: filterMenuChildRowStyle,
        closeOnActivate: false, // 开合子面板,不收父面板
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: filterMenuText(context.t('grid.rating')),
      ),
    ),
  ];
}

/// 格式筛选分区(与评级同设计的级联子面板):「全部」与各格式互斥,
/// 多选并集;选档不收层,点弹层外才收。行 = 格式族图标 + 拉丁短名
///(NEF/JPG/MOV/MP4/HIF,t() 未命中原文直传)。勾选态读 [selection],
/// 选档沿回调 [onToggle](null = 「全部」,页面 setState 清空)。
List<Widget> formatFilterMenuSection(
  BuildContext context,
  FormatFilterSelection selection,
  void Function(MediaFormat? f) onToggle,
) {
  final scheme = Theme.of(context).colorScheme;
  return [
    MenuAnchor(
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd, // 子面板右缘随行,级联内缩
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('formatFilter-all'),
          style: filterMenuRowStyle,
          closeOnActivate: false, // 选档不收,点外才收
          leadingIcon: const Icon(Icons.apps, size: kMenuIconSize),
          trailingIcon: filterMenuCheck(context, selection.isAll),
          onPressed: () => onToggle(null),
          child: filterMenuText(context.t('libpage.all')),
        ),
        for (final f in MediaFormat.values)
          MenuItemButton(
            key: ValueKey('formatFilter-${f.name}'),
            style: filterMenuRowStyle,
            closeOnActivate: false, // 选档不收,点外才收
            leadingIcon: Icon(_formatIcon(f), size: kMenuIconSize),
            trailingIcon: filterMenuCheck(context, selection.contains(f)),
            onPressed: () => onToggle(f),
            child: filterMenuText(context.t(f.label)),
          ),
      ],
      builder: (context, controller, child) => MenuItemButton(
        key: const ValueKey('formatFilter-entry'),
        style: filterMenuChildRowStyle,
        closeOnActivate: false, // 开合子面板,不收父面板
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: filterMenuText(context.t('grid.formatFilter')),
      ),
    ),
  ];
}

IconData _formatIcon(MediaFormat f) => switch (f) {
      MediaFormat.nef => Icons.raw_on_outlined,
      MediaFormat.jpg => Icons.image_outlined,
      MediaFormat.hif => Icons.image_outlined,
      MediaFormat.mov => Icons.videocam_outlined,
      MediaFormat.mp4 => Icons.movie_outlined,
    };

/// 文件夹筛选分区(相机相册专属,与格式/评级同设计的级联子面板):
/// 「全部照片」(汇总,空选集)与各文件夹多选并集;选档不收层,点弹层
/// 外才收。[albums] 须含汇总相册(全部照片行 = 清空选集);无文件夹
/// 时页面侧不渲染本分区。勾选态读 [selection],选档沿回调 [onToggle]
///(null = 全部)。
List<Widget> folderFilterMenuSection(
  BuildContext context,
  List<CameraAlbum> albums,
  FolderFilterSelection selection,
  void Function(int? folderHandle) onToggle,
) {
  final scheme = Theme.of(context).colorScheme;
  return [
    MenuAnchor(
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd, // 子面板右缘随行,级联内缩
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
        ),
      ),
      menuChildren: [
        for (final album in albums)
          MenuItemButton(
            key: ValueKey(album.isAggregate
                ? 'folderFilter-all'
                : 'folderFilter-${album.folderHandle}'),
            style: filterMenuRowStyle,
            closeOnActivate: false, // 选档不收,点外才收
            leadingIcon: Icon(
                album.isAggregate ? Icons.apps : Icons.folder_outlined,
                size: kMenuIconSize),
            trailingIcon: filterMenuCheck(
                context,
                album.isAggregate
                    ? selection.isAll
                    : selection.contains(album.folderHandle)),
            onPressed: () =>
                onToggle(album.isAggregate ? null : album.folderHandle),
            child: filterMenuText(context.t(album.name)),
          ),
      ],
      builder: (context, controller, child) => MenuItemButton(
        key: const ValueKey('folderFilter-entry'),
        style: filterMenuChildRowStyle,
        closeOnActivate: false, // 开合子面板,不收父面板
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: filterMenuText(context.t('grid.folderFilter')),
      ),
    ),
  ];
}
