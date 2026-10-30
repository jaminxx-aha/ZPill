/// 设置页/日志页共用的视觉件(第 4 轮 393 设计稿):分组标题 + 16 圆角
/// 卡片、56 起底的行、999 胶囊分段/芯片、琥珀开关。
///
/// 只做样式,不持业务状态;颜色全部取 [AppColors]/ColorScheme,尺寸取
/// [AppSpacing]/[AppRadius]/[AppSizes],文案由调用方经 context.t() 传入。
library;

import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';

/// 设计稿「设置行」最小高度(标题+副标题自然高度常略高于此)。
const double _rowMinHeight = 56;

/// 设置分组:小节标题 + 圆角卡片。卡片内子项默认插 hairline;
/// 自带分隔线的区块(如快照区)可关掉自动插入、自行排布。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.titleKey,
    required this.children,
    this.insertDividers = true,
  });

  final String titleKey;
  final List<Widget> children;
  final bool insertDividers;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final pad = AppBreakpoints.pagePadding(width);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.xl, pad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpacing.xs, bottom: AppSpacing.sm + 2),
            child: Text(
              context.t(titleKey),
              style: AppTypography.bodyS.copyWith(
                color: AppColors.muted(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: insertDividers ? _withDividers(children) : children,
            ),
          ),
        ],
      ),
    );
  }
}

List<Widget> _withDividers(List<Widget> children) {
  final out = <Widget>[];
  for (final child in children) {
    if (out.isNotEmpty) out.add(const Divider(height: 1));
    out.add(child);
  }
  return out;
}

/// 标题 + 副标题的两级文本(设置行通用)。
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.title,
    required this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sub = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: AppTypography.titleS.copyWith(
            color: enabled ? scheme.onSurface : scheme.outline,
          ),
        ),
        if (sub != null && sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            sub,
            style: AppTypography.bodyS.copyWith(
              color: enabled ? AppColors.muted(context) : scheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}

/// 普通设置行:前置图标 + 标题/副标题 + 尾件。带 [onTap] 才显示可点
/// (无真实动作的项不挂 chevron/ripple,避免假按钮)。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final IconData? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _rowMinHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: Row(
          children: [
            if (leading != null) ...[
              Icon(
                leading!,
                size: 22,
                color: enabled ? scheme.onSurfaceVariant : scheme.outline,
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              child: _TitleBlock(
                title: title,
                subtitle: subtitle,
                enabled: enabled,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: enabled ? onTap : null,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      child: content,
    );
  }
}

/// 带控件的设置行:标题/副标题在上,控件占满整行(主题/语言/格式等
/// 分段控件与变宽滑杆同款)。
class SettingsControlRow extends StatelessWidget {
  const SettingsControlRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    required this.child,
  });

  final IconData? leading;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _rowMinHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (leading != null) ...[
                  Icon(leading!, size: 22, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.md),
                ],
                Expanded(
                  child: _TitleBlock(title: title, subtitle: subtitle),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            child,
          ],
        ),
      ),
    );
  }
}

/// 开关行:开关统一琥珀轨道 + 深字色拇指(深浅主题同号)。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsRow(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.onBrandYellow,
        activeTrackColor: AppColors.accentYellow,
        inactiveThumbColor: scheme.outline,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 一个分段选项(值 + 已本地化文案)。
typedef SettingsSegmentOption<T> = ({T value, String label});

/// 999 胶囊分段控件:选中实底统一黄 + 深字,未选透明。
class SettingsSegment<T extends Object> extends StatelessWidget {
  const SettingsSegment({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.showSelectedIcon = true,
  });

  final T value;
  final List<SettingsSegmentOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool showSelectedIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 分段/芯片/输入框样式会顶替 DefaultTextStyle:必须取 textTheme 派生
    // (带 NotoSansSC 回落),裸 AppTypography 会让汉字变豆腐块。
    final labelStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontWeight: FontWeight.w600);
    return SegmentedButton<T>(
      showSelectedIcon: showSelectedIcon,
      selectedIcon: const Icon(Icons.check, size: 16),
      expandedInsets: EdgeInsets.zero,
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
        side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: scheme.outlineVariant)),
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.accentYellow
                : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.onBrandYellow
                : AppColors.ink2(context)),
        textStyle: WidgetStatePropertyAll<TextStyle?>(labelStyle),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.sm)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: [
        for (final option in options)
          ButtonSegment<T>(
            value: option.value,
            label: Text(option.label, maxLines: 1),
          ),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// 999 胶囊芯片(预设档/日志过滤同款):选中实底统一黄,未选描边透明。
class SettingsPillChip extends StatelessWidget {
  const SettingsPillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color:
                  selected ? AppColors.onBrandYellow : scheme.onSurfaceVariant,
            ),
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      selectedColor: AppColors.accentYellow,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: scheme.outlineVariant),
      shape: const StadiumBorder(),
      labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 设置卡片内的文本输入行(作者/版权/水印文本):焦点离开即落库由
/// 调用方的 FocusNode 负责,这里只负责外观。
class SettingsTextField extends StatelessWidget {
  const SettingsTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.md);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          filled: true,
          fillColor: scheme.surface,
          labelStyle: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.muted(context)),
          border: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: AppColors.accentYellow, width: 1.5),
          ),
        ),
      ),
    );
  }
}
