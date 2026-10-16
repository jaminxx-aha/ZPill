/// 连接页状态卡与存储余量卡:连接状态的进度感(connecting/pairing
/// 内嵌 spinner)、失败原因两段排版 + 重试;双卡槽余量条。
library;

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/browser/storage_info.dart';
import '../../core/camera/camera_connection.dart';
import '../../design/app_colors.dart';
import '../../design/app_dimens.dart';
import '../../l10n/l10n.dart';
import '../browser/storage_overview_controller.dart';
import '../common/format.dart';

/// 连接状态卡:状态色一行 + 阶段文案;connecting/pairing/detecting
/// 尾槽 14px spinner(死 IP 的 TCP 超时最长 ~5s,转圈才有「在干活」的
/// 可感知进度);失败态副文显示 [hint](首句加粗、详情换行,错误字符串
/// 本身不动)+ 重试钮。
class ConnectionStatusCard extends StatelessWidget {
  const ConnectionStatusCard({
    super.key,
    required this.state,
    this.waitingConfirm = false,
    this.hint,
    this.onRetry,
  });

  final CameraLinkState state;

  /// 配对后的机身确认等待窗(真机:相机弹「配对完成」等按 OK)——
  /// 期间状态保持 connecting,用专属文案替代「连接中…」。
  final bool waitingConfirm;

  /// 状态提示(失败原因/配对等待指引);null 不占位。
  final String? hint;

  /// 失败重试(重放最近一次连接尝试)。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = switch (state) {
      CameraLinkState.detecting ||
      CameraLinkState.connecting ||
      CameraLinkState.pairing ||
      CameraLinkState.reconnecting => true,
      _ => false,
    };
    final (label, color) = switch (state) {
      CameraLinkState.disconnected => ('conn.notConnected', scheme.onSurfaceVariant),
      CameraLinkState.detecting => ('conn.detectingWifi', scheme.primary),
      CameraLinkState.connecting when waitingConfirm =>
        ('conn.waitingPairConfirm', scheme.secondary),
      CameraLinkState.connecting => ('conn.connecting', scheme.primary),
      CameraLinkState.pairing => ('conn.waitingPairing', scheme.secondary),
      CameraLinkState.connected => ('conn.connected', AppColors.success(context)),
      CameraLinkState.reconnecting => ('conn.reconnecting', scheme.secondary),
      CameraLinkState.failed => ('conn.failed', scheme.error),
    };
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lan, color: color),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  // label 即 t() 键(switch 内吐抽象键),显示点统一包 t()。
                  child: Text(
                    context.t(label),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color),
                  )
                else
                  Icon(Icons.circle, color: color, size: 12),
              ],
            ),
            if (hint != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _HintText(
                text: hint!,
                color: state == CameraLinkState.failed
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ],
            if (state == CameraLinkState.failed && onRetry != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(context.t('common.retry')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// hint 两段排版:按首个「:」拆首句/详情(「连不上 x.x.x.x:…」/
/// 「相机拒绝了连接(InitFail…):…」)。无冒号整行直出。
class _HintText extends StatelessWidget {
  const _HintText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style =
        TextStyle(color: color, fontSize: 13, height: 1.45);
    // 消费点统一包 t():静态文案在控制器/连接层吐抽象键,带 $e 插值的
    // 运行期串不是键,两表未命中经直通原样回落中文。
    final localized = context.t(text);
    final idx = localized.indexOf(':');
    if (idx < 0) {
      return Text(localized, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localized.substring(0, idx + 1),
            style: style.copyWith(fontWeight: FontWeight.w600)),
        Text(localized.substring(idx + 1), style: style),
      ],
    );
  }
}

/// 双卡槽余量卡(读卡器信息):每槽一行(名 + 剩余/总容量 + 余量进度
/// 条 + 写入中徽标),卡尾可拍张数一行。相机未上报容量只显示名字;
/// 无槽不占位。(相册页删除后随相机信息卡组落户此处。)
class StoragePanel extends StatelessWidget {
  const StoragePanel({super.key, this.overview});

  /// 测试缝:缺省走 AppServices 全局单例。
  final StorageOverviewController? overview;

  @override
  Widget build(BuildContext context) {
    final source = overview ?? AppServices.instance.storageOverview;
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final storages = source.storages;
        if (storages.isEmpty) {
          return const SizedBox.shrink();
        }
        final slot = source.activeSlot;
        // 可拍张数真机两卡沿严格相等(0x1005 自报值),取首个 >0 卡尾一行。
        final shots = storages
            .map((s) => s.freeSpaceImages)
            .firstWhere((n) => n > 0, orElse: () => 0);
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Column(
              children: [
                for (var i = 0; i < storages.length; i++)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: _StorageRow(
                      storage: storages[i],
                      ordinal: i,
                      // 记录槽 0xD1F2:1=槽1/2=槽2/3=双槽(0/未知不标)。
                      writing: slot != null && (slot == i + 1 || slot == 3),
                    ),
                  ),
                if (shots > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.t('conn.shotsLeft', {'n': '$shots'}),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({
    required this.storage,
    required this.ordinal,
    required this.writing,
  });

  final CameraStorage storage;
  final int ordinal;

  /// 当前记录槽命中本行(写卡中)。
  final bool writing;

  /// 展示名:相机描述 → 卷标 → 「插槽 n」按行序兜底(不走模型 hex
  /// 兜底,真机 description/volumeLabel 均空时键名兜底)。
  String _label(BuildContext context) {
    final d = storage.description;
    if (d != null && d.isNotEmpty) return d;
    final v = storage.volumeLabel;
    if (v != null && v.isNotEmpty) return v;
    return context.t('conn.slot', {'n': '${ordinal + 1}'});
  }

  @override
  Widget build(BuildContext context) {
    final ratio = storage.freeRatio;
    final colorScheme = Theme.of(context).colorScheme;
    // 低余量(<10%)转警示色。
    final barColor =
        ratio != null && ratio < 0.1 ? colorScheme.error : colorScheme.primary;
    return Row(
      children: [
        Icon(Icons.sd_card_outlined,
            size: 20, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(_label(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  if (writing) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        context.t('conn.writing'),
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                                color: colorScheme.onSecondaryContainer),
                      ),
                    ),
                  ],
                ],
              ),
              if (ratio != null) ...[
                const SizedBox(height: AppSpacing.xs),
                LinearProgressIndicator(
                  value: 1 - ratio, // 已用占比
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Text(
          storage.maxCapacityBytes > 0
              ? context.t('conn.capacity', {
                  'free': formatBytes(storage.freeSpaceBytes),
                  'total': formatBytes(storage.maxCapacityBytes)
                })
              : context.t('conn.capacityUnknown'),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
