/// 设置仓库(TODO.md §五 P2/P3)。
///
/// TODO(P2): autoTransfer 持久化(shared_preferences,DataStore 等价);
/// TODO(P3): quality / batterySaver / customSavePath。
library;

import 'dart:async';

enum TransferQuality { original, compressed }

final class AppSettings {
  const AppSettings({
    this.autoTransfer = false,
    this.quality = TransferQuality.original,
    this.batterySaver = false,
    this.customSavePath,
  });

  final bool autoTransfer; // P2:自动传输开关
  final TransferQuality quality; // P3:传输质量
  final bool batterySaver; // P3:省电模式
  final String? customSavePath; // P3:自定义存储路径

  AppSettings copyWith({
    bool? autoTransfer,
    TransferQuality? quality,
    bool? batterySaver,
    String? customSavePath,
  }) =>
      AppSettings(
        autoTransfer: autoTransfer ?? this.autoTransfer,
        quality: quality ?? this.quality,
        batterySaver: batterySaver ?? this.batterySaver,
        customSavePath: customSavePath ?? this.customSavePath,
      );
}

abstract interface class SettingsStore {
  Stream<AppSettings> get settings;
  Future<AppSettings> current();
  Future<void> update(AppSettings settings);
}

final class InMemorySettingsStore implements SettingsStore {
  final _controller = StreamController<AppSettings>.broadcast();
  AppSettings _value = const AppSettings();

  @override
  Stream<AppSettings> get settings => _controller.stream;

  @override
  Future<AppSettings> current() async => _value;

  @override
  Future<void> update(AppSettings settings) async {
    _value = settings;
    _controller.add(settings);
  }
}
