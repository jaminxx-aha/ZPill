import 'package:flutter/material.dart';

import 'features/shell/home_shell.dart';

/// 应用根。
///
/// 结构:底部导航四 tab(相机 / 拍摄 / 图库 / 设置,见 HomeShell)。
class NikonPillApp extends StatelessWidget {
  const NikonPillApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NikonPill',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFC400)),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
