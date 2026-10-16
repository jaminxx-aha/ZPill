/// 视频 LUT 导出的选表底部单(任务 20):内置风格列表 + 剪贴板导入
/// 入口。纯选表件 —— 点选项即回 [onPick],导入/导出流程归宿主
/// (查看器),测试不碰平台视图。
///
/// 剪贴板入口语义与编辑页 LUT 面板同链(.cube 文本 / XMP RGBTable
/// 分派),解析在宿主回调里做,本件零协议知识。
library;

import 'package:flutter/material.dart';

import '../../core/media/cube_lut.dart';
import '../../l10n/l10n.dart';
import '../edit/lut_presets.dart' show builtinLuts, lutTitleKey;

class LutExportSheet extends StatelessWidget {
  const LutExportSheet({
    super.key,
    required this.onPick,
    required this.onImportFromClipboard,
  });

  /// 点任一 LUT(含剪贴板导入成功后)。
  final void Function(CubeLut lut) onPick;

  /// 剪贴板导入入口(宿主解析 + 失败提示;成功由宿主转 onPick)。
  final Future<void> Function() onImportFromClipboard;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(context.t('lut.style'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final lut in builtinLuts)
            ListTile(
              dense: true,
              title: Text(context.t(lutTitleKey(lut.title))),
              onTap: () => onPick(lut),
            ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.content_paste),
            title: Text(context.t('edit.importClipboard')),
            onTap: () => onImportFromClipboard(),
          ),
        ],
      ),
    );
  }
}
