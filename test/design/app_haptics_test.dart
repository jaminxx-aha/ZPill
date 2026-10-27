import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:z_pill/design/app_haptics.dart';

/// AppHaptics 单测:各语义方法在 TestWidgetsFlutterBinding 下调用不炸,
/// 且平台方法通道收到对应的 HapticFeedback 强度参数(官方 mock channel
/// pattern:拦 SystemChannels.platform 的 HapticFeedback.vibrate 记参;
/// 其余消息回 null,与默认 mock 行为一致,不影响别的平台调用)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 记录 HapticFeedback.vibrate 的 arguments(强度档位串)。
  List<String?> spyHaptics(WidgetTester tester) {
    final calls = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String?);
      }
      return null;
    });
    return calls;
  }

  testWidgets('shutter → lightImpact(快门按下,轻震)', (tester) async {
    final haptics = spyHaptics(tester);
    await AppHaptics.shutter();
    expect(haptics, ['HapticFeedbackType.lightImpact']);
  });

  testWidgets('recordToggle → mediumImpact(录像起停,重一档)', (tester) async {
    final haptics = spyHaptics(tester);
    await AppHaptics.recordToggle();
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('selection → selectionClick(轻量选择,系统级轻点)',
      (tester) async {
    final haptics = spyHaptics(tester);
    await AppHaptics.selection();
    expect(haptics, ['HapticFeedbackType.selectionClick']);
  });

  testWidgets('success → mediumImpact(成功确认,与复制震感统一)',
      (tester) async {
    final haptics = spyHaptics(tester);
    await AppHaptics.success();
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('全部方法连续调用不炸(测试通道默认 mock 即 no-op)',
      (tester) async {
    final haptics = spyHaptics(tester);
    await AppHaptics.shutter();
    await AppHaptics.recordToggle();
    await AppHaptics.selection();
    await AppHaptics.success();
    expect(haptics, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.mediumImpact',
    ]);
  });
}
