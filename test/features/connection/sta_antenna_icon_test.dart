import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/features/connection/sta_antenna_icon.dart';

/// STA 自绘图标形状闸:golden 锁「漏斗天线+两侧双弧波」构图(2026-10-20
/// 对相机 Wi-Fi 菜单原图定稿)。纯 canvas 无文字渲染,跨平台 golden 稳定;
/// 调形改 sta_antenna_icon.dart 坐标后 --update-goldens 重录。
void main() {
  testWidgets('STA 天线图标构图 golden', (tester) async {
    await tester.pumpWidget(
      const RepaintBoundary(
        child: ColoredBox(
          color: Color(0xFF8E8E8E),
          child: Center(child: StaAntennaIcon(size: 96, color: Colors.white)),
        ),
      ),
    );
    await expectLater(
      find.byType(RepaintBoundary),
      matchesGoldenFile('goldens/sta_icon.png'),
    );
  });
}
