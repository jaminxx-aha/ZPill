/// 键值行(标签列自适应):连接页凭据行与照片信息底单共用。
///
/// 旧布局标签列钉死窄宽(SizedBox 44/64):zh 短标签刚好,EN 长词
/// (Password / Captured / Exposure)在 bodyMedium/13px 下超列宽 ——
/// 凭据行折行、底单贴边,行高随之跳。收编为「钉宽 + 宽按标签实测」:
/// [kvLabelWidth] 按同组标签取最长者,同卡/同表各行共用一宽,标签与
/// 值列按最长标签对齐(各按各的 IntrinsicWidth 会让各行值列起点参差);
/// [kvLabelWidth] 的 minWidth 参数保 zh 短标签的既有观感下限(原钉宽
/// 44/64)。标签单行 + 省略兜极端动态串,正常文案实测宽放行不触省略。
///
/// 行高/行距/外边距全由调用方自理([padding] 缺省不包),本件只管
/// 「标签列宽策略 + 单行省略」这一件事。
library;

import 'package:flutter/material.dart';

/// 标签列宽:[TextPainter] 实测 [labels] 在 [style] 下的最长行宽(带
/// 环境 [TextScaler]),不小于 [minWidth]。与 [Text] 同一条测量路,
/// 实测值即排版值 —— 列宽 ≥ 标签自然宽时既不折行也不省略。
///
/// 同组(同卡/同表)多行必须把整组标签一起传入共用一个结果,列才对齐。
double kvLabelWidth(
  BuildContext context, {
  required Iterable<String> labels,
  required TextStyle style,
  double minWidth = 0,
}) {
  final painter = TextPainter(
    text: const TextSpan(),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
  );
  try {
    var width = minWidth;
    for (final label in labels) {
      painter.text = TextSpan(text: label, style: style);
      painter.layout();
      if (painter.width > width) {
        width = painter.width;
      }
    }
    return width;
  } finally {
    painter.dispose();
  }
}

/// 键值行:钉宽标签列([labelWidth] 由 [kvLabelWidth] 供,同组行共用)
/// + 撑满余宽的值 + 可选尾件(复制钮等)。
class KvRow extends StatelessWidget {
  const KvRow({
    super.key,
    required this.labelWidth,
    required this.label,
    required this.value,
    this.labelStyle,
    this.trailing,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.padding,
  });

  /// 标签列宽:同组行共用(见 [kvLabelWidth]);单行独用时传本行标签
  /// 的实测宽即可。
  final double labelWidth;

  /// 标签:单行,超宽省略(正常文案由 [labelWidth] 放行不触省略)。
  final String label;

  /// 值:撑满余宽;字体/行数/省略策略由调用方自理。
  final Widget value;

  /// 标签字体(缺省随环境 DefaultTextStyle)。
  final TextStyle? labelStyle;

  /// 尾件(如复制钮),紧跟值之后。
  final Widget? trailing;

  /// 纵向对齐(缺省居中,同裸 Row)。
  final CrossAxisAlignment crossAxisAlignment;

  /// 行外边距(缺省不包:几何全由调用方定)。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final tail = trailing;
    final row = Row(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            style: labelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(child: value),
        if (tail != null) tail,
      ],
    );
    final rowPadding = padding;
    return rowPadding == null ? row : Padding(padding: rowPadding, child: row);
  }
}
