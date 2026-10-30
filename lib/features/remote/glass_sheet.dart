import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'live_design.dart';

/// 取景页按钮弹层的玻璃底(与拍摄设置浮层同款收口,2026-10-30 用户
/// 定案「点击按钮底部弹出来的框全都改成和设置框一样是透明的」)。
///
/// 弹层 Material 本体透明、无阴影、遮罩不压暗,玻璃只由本件画:
/// 22pt 高斯模糊 + 38% 实底 + 发丝顶边,取景画面原样透过去;上圆角
/// 22(= 全局 BottomSheetTheme 的 AppRadius.lg + 6),底部贴屏缘不圆。
/// 拖拽手柄画在玻璃**里面** —— 框架的 showDragHandle 画在弹层内容
/// 之外,透明底时手柄会悬在玻璃上方的画面上。
class GlassSheetBackground extends StatelessWidget {
  const GlassSheetBackground(
      {super.key, required this.child, this.handle = true});

  final Widget child;

  /// 顶部拖拽手柄(参数/模式底单有,间隔拍摄步进单没有)。
  final bool handle;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    // 玻璃底由 Material 承载(而非 DecoratedBox):ListTile 的水波纹画在
    // 最近的 Material 上,背景色必须同层,否则 ink 被玻璃盖住(框架断言
    // 「ListTile background color or ink splashes may be invisible」)。
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Material(
          color: live.surface.withValues(alpha: 0.38),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 发丝顶边(设置浮层同款描边,裁剪进上圆角)。
              Container(height: 1, color: live.hairline),
              if (handle) _dragHandle(live),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dragHandle(LivePalette live) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Center(
          child: Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: live.muted.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
}

/// 玻璃底弹层:取景页所有按钮弹出的底部弹框统一入口(参数底单/模式
/// 接管/间隔拍摄)。点外部照常收起(遮罩仍在,只是不压暗)。
Future<T?> showGlassModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool handle = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.transparent,
    showDragHandle: false,
    builder: (sheetContext) => GlassSheetBackground(
      handle: handle,
      child: builder(sheetContext),
    ),
  );
}
