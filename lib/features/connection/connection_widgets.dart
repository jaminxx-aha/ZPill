/// 连接页本地组件(2026-10-19 改版定稿):状态行(圆点 + 状态词)、
/// 固定错误位(空置也占位,错误出现/消失不推挤布局)、红色引导卡
/// (蓝牙系统配对 / 唤起 Wi-Fi 手动入网)、节头与分组容器。配色走
/// M3 + [AppColors],视觉对齐 iOS 设置组语言(连接页活在常规明暗
/// 主题,不引 LiveDesign 黑 chrome)。
library;

import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';

/// 状态行:12px 状态圆点 + 状态词(w600)+ busy 尾槽 16px spinner
/// (连接在途允许转圈;页面扫描一律静默不出圈)。label 传**已 t()**
/// 的状态词。
class ConnStatusHeader extends StatelessWidget {
  const ConnStatusHeader({
    super.key,
    required this.dotColor,
    required this.label,
    this.busy = false,
  });

  final Color dotColor;
  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
          ),
        ),
        if (busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: theme.colorScheme.primary),
          ),
      ],
    );
  }
}

/// 固定错误位(2026-10-19 用户定稿):恒占 [height] 高的透明占位,
/// [hint] 非空才落字 —— 错误出现/消失不推挤下方组件(图标/按钮/列表
/// 位置纹丝不动)。[error] = 失败红字;否则次级色(重连动态文案/
/// 配对等待指引)。hint 即 t() 键或运行期动态串([ConnHintText] 统一
/// 包 t(),动态串两表未命中直通)。
class ConnErrorSlot extends StatelessWidget {
  const ConnErrorSlot({
    super.key,
    this.hint,
    this.error = false,
    this.height = 44,
  });

  final String? hint;
  final bool error;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: hint == null
          ? null
          : Align(
              alignment: Alignment.topLeft,
              child: ConnHintText(
                text: hint!,
                color: error
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }
}

/// hint 两段排版:按首个「:」拆首句/详情(「连不上 x.x.x.x:…」/
/// 「相机拒绝了连接(InitFail…):…」)。无冒号整行直出。text 即
/// t() 键或运行期动态串。
class ConnHintText extends StatelessWidget {
  const ConnHintText({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: color, fontSize: 13, height: 1.45);
    // 消费点统一包 t():静态文案在控制器/连接层吐抽象键,带 $e 插值的
    // 运行期串不是键,两表未命中经直通原样回落中文。
    final localized = context.t(text);
    final idx = localized.indexOf(':');
    if (idx < 0) {
      return Text(localized, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localized.substring(0, idx + 1),
            style: style.copyWith(fontWeight: FontWeight.w600)),
        Text(localized.substring(idx + 1), style: style),
      ],
    );
  }
}

/// 红色引导卡(2026-10-19 改版:App 不主动跳系统设置,页内引导手动
/// 操作):标题 + 编号步骤 + 可选附加行(如热点密码)。蓝牙系统配对
/// 与唤起 Wi-Fi 手动入网两卡共用;title/steps 传**已 t()** 文本。
class ConnGuideCard extends StatelessWidget {
  const ConnGuideCard({
    super.key,
    required this.title,
    required this.steps,
    this.children = const [],
  });

  final String title;
  final List<String> steps;

  /// 步骤之下的附加行(密码/复制等),与步骤同缩进。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700, color: scheme.error),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    child: Text('${i + 1}.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(steps[i],
                        style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.5, color: theme.colorScheme.onSurface)),
                  ),
                ],
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// 分组节头(iOS 设置组标题语言):小号次级色,左对齐组内 tile 文字。
/// 传键就地 t()(消费点统一包 t() 约定)。
class ConnSectionHeader extends StatelessWidget {
  const ConnSectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Text(
        context.t(label),
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 「最近」徽(2026-10-19 八轮):最近连接条目名后的绿底小标签(STA
/// 已配对首条 / BLE 配对档案行 —— hero 点按连的就是这条)。
class ConnRecentBadge extends StatelessWidget {
  const ConnRecentBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.success(context),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        context.t('conn.recent'),
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
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
