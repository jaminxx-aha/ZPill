import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'remote_action_row.dart';
import 'remote_controller.dart';

/// 竖屏底部五键(从左到右):相册 / AF / 快门 / 接管 / 设置。
/// 快门在屏幕正中,三组同一 Row 垂直居中 —— 侧键中心线自动与快门
/// 圆心对齐(393:底距 46 + 88/2 = 90;430:46 + 94/2 = 93)。
class CapturePortraitKeys extends StatelessWidget {
  const CapturePortraitKeys({
    super.key,
    required this.controller,
    required this.mode,
    required this.sideSize,
    required this.shutterSize,
    required this.horizontalPadding,
    required this.onAlbum,
    required this.onTakeoverRequest,
    required this.onSettings,
    this.onFocus,
  });

  final RemoteController controller;
  final CaptureMode mode;
  final double sideSize;
  final double shutterSize;
  final double horizontalPadding;
  final VoidCallback onAlbum;
  final Future<bool> Function(BuildContext context) onTakeoverRequest;
  final VoidCallback onSettings;

  /// 可选覆盖(AF 仍默认由控制器直驱;页面不必接)。
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final side = <Widget>[
      AlbumThumbButton(
          key: const ValueKey('capture-album'),
          controller: controller,
          onTap: onAlbum,
          size: sideSize),
      const SizedBox(width: 8),
      onFocus == null
          ? CaptureFocusButton(
              key: const ValueKey('capture-af'),
              controller: controller,
              size: sideSize,
            )
          : _FocusTap(
              onTap: onFocus!,
              child: CaptureFocusButton(
                controller: controller,
                size: sideSize,
              ),
            ),
    ];
    final right = <Widget>[
      _TakeoverKey(
          controller: controller, size: sideSize, onRequest: onTakeoverRequest),
      const SizedBox(width: 8),
      CaptureCircleButton(
        key: const ValueKey('capture-settings'),
        icon: Icons.tune,
        tooltip: context.t('remote.settingsTooltip'),
        onTap: onSettings,
        size: sideSize,
      ),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: SizedBox(
        height: shutterSize,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: side,
              ),
            ),
            CaptureShutterButton(
                key: const ValueKey('capture-shutter'),
                controller: controller,
                mode: mode,
                size: shutterSize),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TakeoverKey extends StatelessWidget {
  const _TakeoverKey({
    required this.controller,
    required this.size,
    required this.onRequest,
  });

  final RemoteController controller;
  final double size;
  final Future<bool> Function(BuildContext context) onRequest;

  @override
  Widget build(BuildContext context) {
    final active = controller.takeoverActive;
    return CaptureCircleButton(
      key: const ValueKey('capture-takeover'),
      // 接管 = APP 遥控机身:遥控器图标;激活同形染金(lock 锁形易读成
      // 安全锁,2026-10-30 用户要求换掉)。
      icon: Icons.settings_remote,
      active: active,
      tooltip: context.t(active ? 'takeover.active' : 'takeover.title'),
      onTap: !controller.linkUp
          ? null
          : active
              ? controller.releaseTakeover
              : () => unawaited(onRequest(context)),
      size: size,
    );
  }
}

class _FocusTap extends StatelessWidget {
  const _FocusTap({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: onTap, child: child);
}
