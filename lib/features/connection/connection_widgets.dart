/// 连接页本地组件(2026-10-17 界面对齐现代语言):拍摄页信息胶囊
/// (remote_info_pill)同款语言 —— 圆角 999 / 1px hairline 描边 / 状态
/// 点,配色走 M3 + [AppColors](连接页活在常规明暗主题,不引 LiveDesign
/// 黑chrome)。就两个件,再多就该升 lib/design 了。
library;

import 'package:flutter/material.dart';

import '../../design/app_dimens.dart';

/// 状态胶囊:8px 状态点 + 状态词(+可选尾随名)。
class ConnStatusPill extends StatelessWidget {
  const ConnStatusPill({
    super.key,
    required this.dotColor,
    required this.label,
    this.trailing,
  });

  final Color dotColor;
  final String label;

  /// 尾随名(如已配对身份的控制器名),次级色省略号收尾。
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: dotColor),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                trailing!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分组容器:surfaceContainerLow 圆角底包 tiles,tile 间 1px
/// outlineVariant 分隔(iOS 设置组同款语言;子项自带水平 padding)。
class ConnTileGroup extends StatelessWidget {
  const ConnTileGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      // ListTile 在最近 Material 祖先上画底/墨效:透明 Material 垫在
      // DecoratedBox 与子项之间,否则框架断言「背景色会盖住 ink」。
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant,
                  indent: 16,
                  endIndent: 16,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
