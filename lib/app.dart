import 'package:flutter/material.dart';

import 'features/shell/home_shell.dart';

/// 应用根。
///
/// 结构对应 TODO.md §七:底部导航三 tab(相机 / 浏览 / 传输);
/// 设置页、遥控页(P3)从相机页 push 进入。
class NikonBridgeApp extends StatelessWidget {
  const NikonBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NikonBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFC400)),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
