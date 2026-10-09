import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_pill/features/common/widgets/video_conform.dart';
import 'package:nikon_pill/platform/video_player.dart';

final class _FakePlayer implements VideoPlayer {
  _FakePlayer(this.fps);

  final double? fps;
  final List<(String, double)> played = [];

  @override
  Future<double?> frameRate(String path) async => fps;

  @override
  Future<void> play(String path, {double rate = 1.0}) async {
    played.add((path, rate));
  }

  @override
  Future<Uint8List> thumbnail(String path, {required int maxPixelSize}) async {
    throw UnimplementedError();
  }
}

/// 按钮触发一次播放;Completer 收返回值(是否真正发起播放)。
Future<Completer<bool>> _launch(WidgetTester tester, VideoPlayer player) async {
  final done = Completer<bool>();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              unawaited(playVideoWithConform(context,
                      player: player, path: '/a.mov')
                  .then(done.complete));
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  ));
  return done;
}

void main() {
  testWidgets('帧率未知 → 实时直放,不弹门', (tester) async {
    final player = _FakePlayer(null);
    final done = await _launch(tester, player);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('高帧率素材'), findsNothing);
    expect(player.played, [('/a.mov', 1.0)]);
    expect(done.isCompleted, isTrue);
    expect(await done.future, isTrue);
  });

  testWidgets('30fps 不算高帧率 → 实时直放', (tester) async {
    final player = _FakePlayer(30);
    await _launch(tester, player);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('高帧率素材'), findsNothing);
    expect(player.played, [('/a.mov', 1.0)]);
  });

  testWidgets('60fps → 弹门,顺帧档按 24/fps 播放', (tester) async {
    final player = _FakePlayer(60);
    final done = await _launch(tester, player);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('高帧率素材'), findsOneWidget);
    expect(find.textContaining('60 → 24 fps · 40%'), findsOneWidget);
    expect(player.played, isEmpty); // 门未过不起播

    await tester.tap(find.text('24fps 顺帧 · 40%'));
    await tester.pumpAndSettle();

    expect(player.played, [('/a.mov', 0.4)]);
    expect(done.isCompleted, isTrue);
    expect(await done.future, isTrue);
  });

  testWidgets('60fps → 实时播放档 rate 1.0', (tester) async {
    final player = _FakePlayer(60);
    final done = await _launch(tester, player);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('实时播放'));
    await tester.pumpAndSettle();

    expect(player.played, [('/a.mov', 1.0)]);
    expect(done.isCompleted, isTrue);
    expect(await done.future, isTrue);
  });

  testWidgets('60fps 栏外取消 → 不播,返回 false', (tester) async {
    final player = _FakePlayer(60);
    final done = await _launch(tester, player);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // 栏外 = 取消
    await tester.pumpAndSettle();

    expect(player.played, isEmpty);
    expect(done.isCompleted, isTrue);
    expect(await done.future, isFalse);
  });
}
