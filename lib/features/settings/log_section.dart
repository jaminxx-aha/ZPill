/// 设置页「诊断日志」区块(AppLog 是全局静态,无需 controller)。
///
/// 入口 ListTile → 查看页:环形缓冲 dump 进等宽滚动列表,支持刷新 /
/// 复制全部到剪贴板 / 写 `dataDir/logs/` 导出文件。导出走已装配的
/// gallery 通道取目录 + dart:io 直写,不新建导出 channel;分享面板
/// (share sheet)三端各异,留待后续。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/log/app_log.dart';
import '../../l10n/l10n.dart';
import '../../platform/services.dart';

/// 设置页的日志区块(样式对齐 buildSnapshotSection:Divider + ListTile)。
Widget buildLogSection(BuildContext context) {
  return Column(
    children: [
      const Divider(),
      ListTile(
        leading: const Icon(Icons.receipt_long),
        title: Text(context.t('log.title')),
        subtitle: Text(context.t('log.subtitle', {
          'n': AppLog.entries.length,
          'cap': AppLog.defaultCapacity,
        })),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const LogViewerPage()),
        ),
      ),
    ],
  );
}

/// 日志查看页:等宽全文 + 刷新/复制/存文件。
final class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

final class _LogViewerPageState extends State<LogViewerPage> {
  String _text = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _text = AppLog.dump());
  }

  /// 导出全文 = 头注(时间/条数)+ 全量 dump。
  String _exportText() {
    return context.t('log.header', {
          'time': DateTime.now().toIso8601String(),
          'n': AppLog.entries.length,
        }) +
        _text;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _exportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.t('log.copied', {'n': AppLog.entries.length})),
    ));
  }

  Future<void> _save() async {
    if (_busy) return;
    // 落盘前置齐全部 context 依赖(await 后不再碰 widget 树取文案)。
    final text = _exportText();
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    final name = 'export-${now.year}${p2(now.month)}${p2(now.day)}'
        '-${p2(now.hour)}${p2(now.minute)}${p2(now.second)}.log';
    setState(() => _busy = true);
    try {
      final dataDir = await PlatformServices.gallery.dataDir();
      final logsDir = Directory('$dataDir/logs');
      await logsDir.create(recursive: true);
      final path = '${logsDir.path}/$name';
      await File(path).writeAsString(text, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.t('log.saved', {'path': path})),
      ));
    } on Object catch (e) {
      // StateError(gallery 通道未返回目录)非 Exception,也要落地提示
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.t('log.saveFailed', {'e': e})),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('log.viewerTitle')),
        actions: [
          IconButton(
            tooltip: context.t('log.refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: context.t('log.copy'),
            icon: const Icon(Icons.copy_all),
            onPressed: _text.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: context.t('log.save'),
            icon: const Icon(Icons.save_outlined),
            onPressed: _busy || _text.isEmpty ? null : _save,
          ),
        ],
      ),
      body: _text.isEmpty
          ? Center(child: Text(context.t('log.empty')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _text,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Menlo', 'Courier New'],
                ),
              ),
            ),
    );
  }
}
