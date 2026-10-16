import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/core/log/app_log.dart';
import 'package:nikon_pill/features/settings/log_section.dart';

void main() {
  setUp(AppLog.resetForTest);
  tearDown(AppLog.resetForTest);

  testWidgets('区块显示环形缓冲条数,点击进查看页看到日志行', (tester) async {
    AppLog.i(AppLog.protocol, '→ GetDeviceInfo tid=0');
    AppLog.e(AppLog.usb, 'bulkRead 失败');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            Builder(
                builder: (context) =>
                    buildLogSection(context)), // section 需要 context 取文案
          ],
        ),
      ),
    ));
    expect(find.textContaining('环形缓冲 2/5000'), findsOneWidget);

    await tester.tap(find.text('诊断日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('→ GetDeviceInfo tid=0'), findsOneWidget);
    expect(find.textContaining('[E/usb] bulkRead 失败'), findsOneWidget);
  });

  testWidgets('空缓冲进查看页显示占位', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('复制全部:剪贴板收到头注 + 全量 dump', (tester) async {
    AppLog.w(AppLog.ble, 'BLE 断连');
    Object? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
        }
        return null;
      },
    );

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.tap(find.byIcon(Icons.copy_all));
    await tester.pump();
    await tester.pump(); // SnackBar 浮出

    expect(copied, isA<String>());
    expect(copied as String, contains('NikonPill 诊断日志'));
    expect(copied as String, contains('[W/ble] BLE 断连'));
    expect(find.textContaining('已复制 1 条'), findsOneWidget);
  });

  testWidgets('存文件:裸树无 gallery 通道 → 落「写入失败」提示(不炸)', (tester) async {
    // 回归口径:iOS 通道字节陷阱教训 —— Error(StateError/LateError)类
    // 必须被 on Object 接住,逃逸 = 页面白屏。
    AppLog.i(AppLog.transfer, 't1');
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.tap(find.byIcon(Icons.save_outlined));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('写入失败'), findsOneWidget);
  });
}
