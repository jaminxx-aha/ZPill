import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import 'live_design.dart';

/// 取景区底边横幅(OpenZCine「坐在画面下沿」口径):玻璃底 + 语义色
/// 描边与文字;[bottomInset] 让位底部浮层(动作行等)。**恒用暗面**
/// (LiveDesign.dark):横幅是叠在取景画面上的内容层,不随应用主题。
/// **长按复制**(2026-10-17 用户需求:报错码要能贴回开发侧)。
class LiveBanner extends StatelessWidget {
  const LiveBanner(this.text, this.color,
      {super.key, this.bottomInset = 0, this.onLongPress});

  final String text;
  final Color color;
  final double bottomInset;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        margin: EdgeInsets.fromLTRB(16, 0, 16, 10 + bottomInset),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: LiveDesign.dark.glass,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 12),
            textAlign: TextAlign.center),
      ),
    );
  }
}

/// 横幅宿主(显隐节律在视图层,不侵入 RemoteController):
/// - 提示([autoDismiss],good):**4s 后淡出** —— 拍完「已拍摄」一类
///   快讯不赖着挡画面;
/// - 错误(bad):**不自动消失**,8s 后收起为 28px 圆丸(bad 描边 + !),
///   点按展开原文(展开后不再自动收起)—— 诊断留档与不遮挡的折中;
/// - 消息文本变更(新错误/新提示)= 重展开重计时;
/// - 长按复制原文进剪贴板(错误码要能贴回开发侧,2026-10-17 用户
///   需求),已收圆丸长按同效;展开态复制后原文短暂换显「已复制」。
///
/// 取景区每帧重建(AnimatedBuilder merge 监听),横幅树位不变、State
/// 存续,计时不受重建打断;消息对账在 didUpdateWidget。
class LiveBannerHost extends StatefulWidget {
  const LiveBannerHost(this.message, this.color,
      {super.key, this.bottomInset = 0, this.autoDismiss = false});

  final String message;
  final Color color;
  final double bottomInset;

  /// true = 提示节律(4s 淡出);false = 错误节律(8s 收圆丸)。
  final bool autoDismiss;

  @override
  State<LiveBannerHost> createState() => _LiveBannerHostState();
}

class _LiveBannerHostState extends State<LiveBannerHost> {
  Timer? _timer;
  Timer? _copiedTimer;
  bool _hidden = false; // 提示:已淡出
  bool _collapsed = false; // 错误:已收为圆丸
  bool _copied = false; // 长按复制成功短反馈(原文暂换「已复制」)

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(LiveBannerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message != oldWidget.message) {
      _hidden = false;
      _collapsed = false;
      _copied = false;
      _copiedTimer?.cancel();
      _arm();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  /// 长按复制原文(未翻译键经 t() 同屏显文本,动态串直通)。复制成功
  /// 震一下,展开/提示态原文暂换「已复制」1.2s。
  void _copy() {
    Clipboard.setData(ClipboardData(text: context.t(widget.message)));
    HapticFeedback.mediumImpact();
    if (_collapsed) return; // 圆丸无文本位,震动即确认
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  String get _shownText =>
      _copied ? context.t('common.copied') : context.t(widget.message);

  void _arm() {
    _timer?.cancel();
    _timer = Timer(
        widget.autoDismiss ? const Duration(seconds: 4) : const Duration(seconds: 8),
        () {
      if (!mounted) return;
      setState(() =>
          widget.autoDismiss ? _hidden = true : _collapsed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // message 原文即 t() 键(RemoteController 的 error/notice 在无
    // BuildContext 处产中文,插值类运行期串无静态键,如实回落中文),
    // 消费点包 t()。
    if (widget.autoDismiss) {
      return AnimatedOpacity(
        opacity: _hidden ? 0 : 1,
        duration: const Duration(milliseconds: 300),
        child: IgnorePointer(
          ignoring: _hidden,
          child: LiveBanner(_shownText, widget.color,
              bottomInset: widget.bottomInset,
              onLongPress: _copy),
        ),
      );
    }
    if (_collapsed) {
      return GestureDetector(
        onTap: () => setState(() => _collapsed = false),
        onLongPress: _copy,
        child: Container(
          width: 28,
          height: 28,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 10 + widget.bottomInset),
          decoration: BoxDecoration(
            color: LiveDesign.dark.glass,
            shape: BoxShape.circle,
            border: Border.all(color: widget.color.withValues(alpha: 0.7)),
          ),
          child:
              Icon(Icons.priority_high, size: 16, color: widget.color),
        ),
      );
    }
    return LiveBanner(_shownText, widget.color,
        bottomInset: widget.bottomInset, onLongPress: _copy);
  }
}
