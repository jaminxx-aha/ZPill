/// 设置页「诊断日志」区块(AppLog 是全局静态,无需 controller)。
///
/// 入口行 → 查看页:按级别/域着色的等宽日志行(域过滤芯片可切)、
/// 刷新 / 复制全部到剪贴板 / 写 `dataDir/logs/` 导出文件。导出走已
/// 装配的 gallery 通道取目录 + dart:io 直写,不新建导出 channel;
/// 分享面板(share sheet)三端各异,留待后续。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/log/app_log.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../../platform/services.dart';
import 'settings_widgets.dart';

/// 设置页的日志入口行(设置卡片内的一行;分隔线由外层卡片负责)。
Widget buildLogSection(BuildContext context) {
  return SettingsRow(
    leading: Icons.receipt_long,
    title: context.t('log.title'),
    subtitle: context.t('log.subtitle', {
      'n': AppLog.entries.length,
      'cap': AppLog.defaultCapacity,
    }),
    trailing: Icon(Icons.chevron_right, color: AppColors.muted(context)),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LogViewerPage()),
    ),
  );
}

/// 日志查看页:等宽全文 + 刷新/复制/存文件。
final class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

/// 日志域过滤(词表暂无独立键的档位按技术专名/既有键取文案;见各值注释)。
enum _LogFilter {
  all,
  ble,

  /// PTP 协议域(AppLog.protocol)。PTP 为技术专名,两语种同形不译。
  ptp,
  transfer;

  String label(BuildContext context) => switch (this) {
        all => context.t('common.all'),
        ble => context.t('conn.bluetooth'),
        ptp => 'PTP',
        transfer => context.t('transfers.title'),
      };

  bool allows(AppLogEntry entry) => switch (this) {
        all => true,
        ble => entry.domain == AppLog.ble,
        ptp => entry.domain == AppLog.protocol,
        transfer => entry.domain == AppLog.transfer,
      };
}

final class _LogViewerPageState extends State<LogViewerPage> {
  List<AppLogEntry> _entries = const [];
  String _text = '';
  bool _busy = false;
  _LogFilter _filter = _LogFilter.all;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _entries = AppLog.entries;
      _text = AppLog.dump();
    });
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
        toolbarHeight: AppSizes.appBarPortrait,
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
      body: Column(
        children: [
          _filterBar(context),
          Expanded(child: _logList(context)),
        ],
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final pad = AppBreakpoints.pagePadding(width);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.sm, pad, AppSpacing.sm),
      child: Row(
        children: [
          for (final filter in _LogFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: SettingsPillChip(
                label: filter.label(context),
                selected: _filter == filter,
                onSelected: () => setState(() => _filter = filter),
              ),
            ),
        ],
      ),
    );
  }

  Widget _logList(BuildContext context) {
    final entries = [
      for (final entry in _entries)
        if (_filter.allows(entry)) entry,
    ];
    if (entries.isEmpty) {
      // 真空缓冲才说「暂无日志」;仅本档无命中用既有「无」键。
      return Center(
        child: Text(
          context.t(_entries.isEmpty ? 'log.empty' : 'common.none'),
          style: TextStyle(color: AppColors.muted(context)),
        ),
      );
    }
    return SelectionArea(
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        itemCount: entries.length,
        separatorBuilder: (_, index) => const Divider(height: 1),
        itemBuilder: (_, index) => _LogRow(entry: entries[index]),
      ),
    );
  }
}

/// 单条日志:等宽时间 + 级别/域着色 + 正文。正文原样保留
/// `[E/domain] message` 形态(复制/导出口径与存量一致)。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final AppLogEntry entry;

  static String _timeOf(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      AppLogLevel.debug => AppColors.success(context),
      AppLogLevel.info => AppColors.info(context),
      AppLogLevel.warn => scheme.secondary,
      AppLogLevel.error => scheme.error,
    };
    final symbol = const ['D', 'I', 'W', 'E'][entry.level.index];
    final mono = TextStyle(
      fontFamily: 'monospace',
      // 日志正文含中文:随包 Noto Sans SC 兜底(测试 harness 无系统字体)。
      fontFamilyFallback: const ['Menlo', 'Courier New', 'NotoSansSC'],
      fontSize: 12,
      height: 1.45,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 9),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${_timeOf(entry.time)} ',
              style: mono.copyWith(color: AppColors.muted(context)),
            ),
            TextSpan(
              text: '[$symbol/${entry.domain}] ',
              style: mono.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: entry.message,
              style: mono.copyWith(color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
