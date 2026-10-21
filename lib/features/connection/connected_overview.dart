/// 已连接总览(bento 卡片风,2026-10-17 v26 交付稿定样):状态行
/// (绿点 + 横置电池壳嵌电量数字 + 链路纯图标 pill)+ 机身整行卡
/// (中线分割:型号 pill | 固件/序列号裸值,列位与存储卡贯通)+
/// 镜头信息|存储双列卡(镜头卡合并焦距/光圈实况;存储卡每槽卡型
/// 图标 + 记录槽绿点 + 已用/总量 + 6px 胶囊条,填充 = 已用量、百分
/// 比居中条内)。图标扛语义(固件/序列号/焦距/光圈沿用改造前 info
/// 行的原图标),设备名/链路详情收进状态行点按弹层。数据全来自既
/// 有控制器,零新增协议读。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/storage_info.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../browser/storage_overview_controller.dart';
import 'connection_widgets.dart';
import '../remote/remote_controller.dart';
import '../remote/remote_info_pill.dart';

/// 机型 → 各槽卡型短标(l10n 键,序 = 物理槽位-1)。协议无卡型字段
/// (官方 Zf USB MTP 指令书:StorageInfo 的 StorageType 恒 Removable
/// Ram、StorageDescription 相机不使用),按公开硬件规格映射;只录已
/// 核实的机型,未收录一律回落相机上报原文。物理槽位从 description
/// 的「[Slot n]」解析 —— 单插槽 2 时按列表序兜底会错标。
const Map<String, List<String>> kCardTypesByModel = {
  'zf': ['conn.cardSdShort', 'conn.cardMicroSdShort'],
};

final RegExp _slotInDescription =
    RegExp(r'\[Slot\s*(\d+)\]', caseSensitive: false);

/// 物理槽位(1 基):description「[Slot n]」解析优先(单插槽 2 时
/// 列表序会错标),解析不到退列表序 n。
int _physicalSlot(CameraStorage storage, int ordinal) {
  final d = storage.description;
  if (d != null) {
    final m = _slotInDescription.firstMatch(d);
    if (m != null) return int.parse(m.group(1)!);
  }
  return ordinal + 1;
}

/// GB 容量紧凑格式:≥10GB 取整,<10GB 留一位。总量带单位(23/119GB
/// 的 GB 只缀在总量后,用户 2026-10-17 定稿)。
String _formatGb(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  return gb >= 10 ? '${gb.round()}GB' : '${gb.toStringAsFixed(1)}GB';
}

/// 已用 GB 数(不带单位):口径同 [_formatGb] 但只出数字。
String _gbNumber(int bytes) {
  final gb = bytes / (1024 * 1024 * 1024);
  return gb >= 10 ? '${gb.round()}' : gb.toStringAsFixed(1);
}

/// 焦距显示:整值不带小数(40mm),非整带一位(35.5mm)。
String _formatFocalMm(double mm) => mm == mm.roundToDouble()
    ? '${mm.toInt()}mm'
    : '${mm.toStringAsFixed(1)}mm';

/// 图标 + 读数行(22px 图标列 + 固定字列,与存储卡槽行同列位语法)。
class _IconTextRow extends StatelessWidget {
  const _IconTextRow({
    required this.icon,
    required this.text,
    this.fontSize = 13,
  });

  final IconData icon;
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Center(
            // 图标统一品牌黄(亮题也黄,2026-10-17 用户定稿;暗题
            // primary 本就是同值)。
            child: Icon(icon, size: 18, color: AppColors.accentYellow),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 状态行:绿点 + 已连接(w700)| 电池 chip + 链路纯图标 pill。
/// 整行可点 → 详情/断开弹层(设备名、链路串随迁,2026-10-17 定稿)。
class ConnectedHeader extends StatelessWidget {
  const ConnectedHeader({
    super.key,
    this.batteryPercent,
    required this.linkIcon,
    this.onTap,
  });

  final int? batteryPercent;

  /// 链路图标(页面按无线/有线给 wifi/usb;详情串在弹层)。
  final IconData linkIcon;

  /// 点按状态行:打开连接详情弹层。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battery = batteryPercent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        // 行高钉 [kConnStatusRowHeight](pill 26 本就是全行最高件):
        // 与未连接侧状态行共常量,尾部内容增减不牵动左簇位置。
        child: SizedBox(
          height: kConnStatusRowHeight,
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: AppColors.success(context),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                context.t('conn.connected'),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (battery != null) ...[
                _BatteryGauge(level: battery),
                const SizedBox(width: AppSpacing.md),
              ],
              _LinkPill(icon: linkIcon),
            ],
          ),
        ),
      ),
    );
  }
}

/// 横置电池壳(v26 交付稿定稿):壳内按电量填充(品牌黄),电量数字
/// 嵌壳内、无百分号;填充过半数字转深字保对比度,低电(浅填充)转
/// 亮字。
class _BatteryGauge extends StatelessWidget {
  const _BatteryGauge({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = (level / 100).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 14,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3.5),
            border:
                Border.all(color: scheme.onSurfaceVariant, width: 1.4),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                // 填充:heightFactor 满高 —— Align 松约束下 FSB 不带
                // heightFactor 会让无 child 的 ColoredBox 高度塌 0
                // (2026-10-17 真机实证:亮暗主题填充都不显)。
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: ratio,
                    heightFactor: 1.0,
                    child: ColoredBox(
                        // 电量填充用成功绿(2026-10-17 用户定稿)。
                        color: AppColors.success(context)),
                  ),
                ),
                Center(
                  child: Text(
                    '$level',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: ratio > 0.5 ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 1),
        Container(
          width: 2.5,
          height: 7,
          decoration: BoxDecoration(
            color: scheme.onSurfaceVariant,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    );
  }
}

/// 链路胶囊(ConnStatusPill 同款语言;只留图标,详情在弹层)。
class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 30,
      height: 26,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// bento 卡基座:surfaceContainerLow 底 + lg 圆角 + 1px hairline 描边
/// (亮色主题下卡底≈页面底,描边才可辨)。
class _BentoCard extends StatelessWidget {
  const _BentoCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

/// 机身卡(整行):竖线居中分割 —— 左 = 相机图标 + 型号 pill;
/// 右 = 固件/序列号裸值(改造前 info 行原图标 system_update_alt/tag,
/// 黄色 18px;13 号 w700 与存储卡槽行同字号同列位)。
class CameraCard extends StatelessWidget {
  const CameraCard({
    super.key,
    required this.model,
    required this.firmware,
    required this.serial,
  });

  final String? model;
  final String? firmware;
  final String? serial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _BentoCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(Icons.photo_camera,
                    size: 22, color: AppColors.accentYellow),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      model ?? '--',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 30, color: scheme.outlineVariant),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconTextRow(
                      icon: Icons.system_update_alt_outlined,
                      text: firmware ?? '--'),
                  const SizedBox(height: 6),
                  _IconTextRow(icon: Icons.tag_outlined, text: serial ?? '--'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 镜头信息卡(半宽):镜头名 + 焦距 + 光圈三段等分(2026-10-17 合卡,
/// 原独立参数卡退场);焦距/光圈沿用原 info 行图标 straighten/tilt。
class LensCard extends StatelessWidget {
  const LensCard({
    super.key,
    required this.lensName,
    this.focalMm,
    this.fNumber,
  });

  /// 镜头显示名(0xD0E0 映射营销名,未收录退规格描述)。
  final String? lensName;

  /// 当前焦距 mm(0x5008 ÷100);null = 相机不报或未读到。
  final double? focalMm;

  /// 当前光圈 ×100(280 = ƒ/2.8);null 同上。
  final int? fNumber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _BentoCard(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                child: Icon(Icons.camera,
                    size: 22, color: AppColors.accentYellow),
              ),
              // 6 与 _IconTextRow 同距:三行文字同一起点(40mm/ƒ/2.0
              // 与镜头名对齐,2026-10-17 用户反馈)。
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  lensName ?? '--',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          _IconTextRow(
            icon: Icons.straighten_outlined,
            text: focalMm == null ? '--' : _formatFocalMm(focalMm!),
            fontSize: 14,
          ),
          _IconTextRow(
            icon: Icons.filter_tilt_shift,
            text: fNumber == null
                ? '--'
                : 'ƒ/${(fNumber! / 100).toStringAsFixed(1)}',
            fontSize: 14,
          ),
        ],
      ),
    );
  }
}

/// 组尾脚注(有状态):照片档(或模式未读)「可拍 {n}」;视频档同位
/// 换「可录 {h:mm:ss}」—— 帧头 @816 机身自报,与拍摄页胶囊同源同
/// 口径;无数据显「可录 --」占位(空态比消失可辨),进过拍摄页即有
/// 真值。**换档沿旧档口径张数作废**:视频档 0x9209 镜像张数被机身
/// 录像估算污染,切回照片沿会先闪旧值再被新鲜读纠正(与拍摄页
/// _setCameraMode 清空同款,2026-10-17 用户实证 4197 闪现)—— 翻转
/// 沿隐藏张数 + 主动拉一轮存储信息(别等机身未必推的 0x400C),翻转
/// 后的新列表到达才放行。
class _StorageFooter extends StatefulWidget {
  const _StorageFooter({
    required this.mode,
    required this.videoRemainingMs,
    required this.storages,
    required this.source,
  });

  final CaptureMode? mode;
  final int? videoRemainingMs;
  final List<CameraStorage> storages;
  final StorageOverviewController? source;

  @override
  State<_StorageFooter> createState() => _StorageFooterState();
}

class _StorageFooterState extends State<_StorageFooter> {
  CaptureMode? _lastMode;
  List<CameraStorage>? _lastStorages;
  bool _shotsStale = false;

  @override
  void initState() {
    super.initState();
    _lastMode = widget.mode;
    _lastStorages = widget.storages;
  }

  @override
  void didUpdateWidget(covariant _StorageFooter old) {
    super.didUpdateWidget(old);
    if (widget.mode != _lastMode) {
      _lastMode = widget.mode;
      if (!_shotsStale) {
        _shotsStale = true;
        // 别等 0x400C(机身未必推模式翻转的存储事件):自己拉一轮。
        unawaited(() async {
          try {
            await widget.source?.refresh();
          } catch (_) {
            // 测试桩无脚本/会话已关:静默(生产 refresh 自带 Exception
            // 兜底;StateError 属会话已关,同样不算错)
          }
        }());
      }
    } else if (_shotsStale && !identical(widget.storages, _lastStorages)) {
      _shotsStale = false; // 翻转后的新鲜读到了,放行
    }
    _lastStorages = widget.storages;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shots = widget.storages
        .map((s) => s.freeSpaceImages)
        .firstWhere((n) => n > 0, orElse: () => 0);
    if (widget.mode == CaptureMode.video) {
      final ms = widget.videoRemainingMs;
      final label = (ms != null && ms > 0) ? recRemainingLabel(ms) : '--';
      return Text(
        context.t('conn.recTimeLeft', {'t': label}),
        style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()]),
      );
    }
    if (_shotsStale) {
      // 作废窗口:同款文本全透明占位 —— 行高不塌、组件不跳
      // (2026-10-17 用户实证换档闪跳),污染值不显。
      return Opacity(
        opacity: 0,
        child: Text(
          context.t('conn.shotsLeft', {'n': '$shots'}),
          style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (shots <= 0) {
      return const SizedBox.shrink();
    }
    return Text(
      context.t('conn.shotsLeft', {'n': '$shots'}),
      style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// 存储卡(半宽):每槽 = 卡型图标即槽标(SD 大 / mSD 小,22 列居中,
/// 机型表命中不出文字)+ 记录槽绿点 + 已用/总量(GB 只缀总量后)+
/// 4px 胶囊条(填充 = 已用量、百分比 = 已用 %,亮暗均品牌黄)。组尾
/// 「可拍」为卡底附带脚注,不参与槽块居中;容量未知无条;无槽整卡
/// 退场。
class StorageCard extends StatelessWidget {
  const StorageCard({
    super.key,
    this.overview,
    this.model,
    this.mode,
    this.videoRemainingMs,
  });

  /// 测试缝:缺省走 AppServices 全局单例。
  final StorageOverviewController? overview;

  /// 机身型号(GetDeviceInfo,渐进到货):卡型映射键源;null/未
  /// 收录机型回落相机上报描述。
  final String? model;

  /// 相机当前拍摄模式(0xD1A6 镜像;null = 未读,按照片档走)。
  final CaptureMode? mode;

  /// 视频剩余可录时长(帧头 @816 毫秒,机身自报;null/0 = 无效)。
  final int? videoRemainingMs;

  @override
  Widget build(BuildContext context) {
    final source = overview ?? AppServices.instance.storageOverview;
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final storages = source.storages;
        if (storages.isEmpty) {
          return const SizedBox.shrink();
        }
        final slot = source.activeSlot;
        final slots = <Widget>[];
        for (var i = 0; i < storages.length; i++) {
          final n = _physicalSlot(storages[i], i);
          if (i > 0) slots.add(const SizedBox(height: 12));
          slots.add(_StorageSlot(
            storage: storages[i],
            slotNumber: n,
            model: model,
            // 记录槽 0xD1F2:1=槽1/2=槽2/3=双槽(0/未知不亮);命中
            // 物理槽位而非列表序(单插槽 2 时列表序会漏亮)。
            recording: slot != null && (slot == n || slot == 3),
          ));
        }
        return _BentoCard(
          child: Column(
            // 脚注「可拍」贴左(2026-10-17 定稿);槽块居中由 Expanded
            // 里的 Center 自理,不受此轴影响。
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: slots),
                ),
              ),
              // 与槽块的间距(2026-10-17 用户校准:4px)。
              const SizedBox(height: 4),
              _StorageFooter(
                mode: mode,
                videoRemainingMs: videoRemainingMs,
                storages: storages,
                source: source,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StorageSlot extends StatelessWidget {
  const _StorageSlot({
    required this.storage,
    required this.slotNumber,
    required this.model,
    required this.recording,
  });

  final CameraStorage storage;

  /// 物理槽位(1 基):description「[Slot n]」解析优先,列表序兜底。
  final int slotNumber;

  /// 机身型号(卡型映射键源;null/未收录回落相机上报描述)。
  final String? model;

  /// 当前记录槽命中本行(0xD1F2 ActiveSlot,非实时写卡状态)。
  final bool recording;

  /// 槽名:机型表命中 → SD/mSD(弃相机「NIKON Z f [Slot 1]」原文);
  /// 未收录/无型号沿旧链 相机描述 → 卷标 → 「插槽 n」兜底。
  String _label(BuildContext context) {
    final key = model?.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final types = key == null ? null : kCardTypesByModel[key];
    if (types != null && slotNumber >= 1 && slotNumber <= types.length) {
      return context.t(types[slotNumber - 1]);
    }
    final d = storage.description;
    if (d != null && d.isNotEmpty) return d;
    final v = storage.volumeLabel;
    if (v != null && v.isNotEmpty) return v;
    return context.t('conn.slot', {'n': '$slotNumber'});
  }

  /// 4px 百分比胶囊条(2026-10-17 终稿):填充 = 已用量、百分比 =
  /// 已用 %,同口径不反转(用户定案);亮暗两版填充都用品牌黄(剩余
  /// <10% 转警示红),文字亮题黑/暗题白(onSurface)。文字不参与圆角
  /// 裁切 —— 4px 条容不下 6.5 号字,叠在条上居中。
  Widget _bar(BuildContext context, double freeRatio) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usedRatio = 1 - freeRatio;
    final pct = (usedRatio * 100).round();
    final fillColor =
        freeRatio < 0.1 ? scheme.error : AppColors.accentYellow;
    return SizedBox(
      key: const Key('storageUsageBar'),
      // 满宽:Stack 里唯一的非定位子孩是百分比文字,不给宽的话 Stack
      // 会按文字宽收缩,Positioned.fill 跟着塌成小点(2026-10-17 真机)。
      width: double.infinity,
      // 5px(2026-10-17 用户校准:6→5);文字盒 = 条高(字号 5 +
      // 行高 1.0),零溢出零裁切 —— 条内文字仍可辨的下限附近。
      height: 5,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: AlignmentDirectional.center,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Stack(
                children: [
                  Positioned.fill(
                    child:
                        ColoredBox(color: scheme.surfaceContainerHighest),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: usedRatio.clamp(0.0, 1.0),
                      heightFactor: 1.0,
                      child: ColoredBox(
                          key: const Key('storageBarFill'),
                          color: fillColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 文字必须走定位层:非定位子孩先画,会被轨道/填充盖住
          // (2026-10-17 真机实证,百分比只剩上下残边)。
          Positioned.fill(
            child: Center(
              child: Text(
                '$pct%',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 5,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 槽图标:卡面印卡型字样(仿真卡印刷,黄底深字)—— SD/mSD 档
  /// 统一 7 号「SD」/「m」(2026-10-17 用户校准)。
  Widget _slotIcon(double iconSize) {
    final icon =
        Icon(Icons.sd_card, size: iconSize, color: AppColors.accentYellow);
    final label = iconSize < 20 ? 'm' : 'SD';
    const labelSize = 7.0;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Stack(
        children: [
          Positioned.fill(child: icon),
          Align(
            alignment: const Alignment(0, 0.55),
            child: Text(
              label,
              style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w900,
                height: 1.0,
                letterSpacing: -0.2,
                color: AppColors.onBrandYellow,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final freeRatio = storage.freeRatio;
    // 卡型图标:映射命中才分大小(SD 20 / mSD 13),未收录机型一律大。
    final key = model?.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final mapped = key != null && kCardTypesByModel.containsKey(key);
    final iconSize = mapped && slotNumber == 2 ? 13.0 : 20.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: 22, child: Center(child: _slotIcon(iconSize))),
            const SizedBox(width: 6),
            // 图标即槽标(2026-10-17 定稿):机型表命中 → SD 大图标 /
            // mSD 小图标扛语义,不再出「SD/mSD」文字;未收录机型无
            // 图标语义可依赖,仍回落相机描述/卷标/插槽 n 文字。
            Expanded(
              child: Row(
                children: [
                  if (!mapped)
                    Flexible(
                      child: Text(
                        _label(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (recording) ...[
                    if (!mapped) const SizedBox(width: 4),
                    Container(
                      key: const Key('storageRecordingDot'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: AppColors.success(context),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              storage.maxCapacityBytes > 0
                  ? context.t('conn.usage', {
                      'used':
                          _gbNumber(storage.maxCapacityBytes -
                              storage.freeSpaceBytes),
                      'total': _formatGb(storage.maxCapacityBytes),
                    })
                  : context.t('conn.capacityUnknown'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        if (freeRatio != null) ...[
          const SizedBox(height: 6),
          _bar(context, freeRatio),
        ],
      ],
    );
  }
}
