/// 下拉跟手返回(查看器图片页共享件):垂直拖拽 → 图片跟手平移 +
/// 轻微缩小(布局级,hero 实测盒随之)、顶底 chrome 同步淡出;松手
/// 过阈值提交返回(普通 pop —— Hero 航班以拖拽后的绘制位为起点飞回
/// 格位,绘制变换会进入框架 localToGlobal 实测;fromHero 航班中由
/// 占位件隐藏,无双重成像),不足阈值弹回复位。
///
/// 用法:查看器 State 持有 [PullAwayController](vsync 传入,dispose
/// 归还);body 外包 [PullAwayTransform],appBar/底栏外包
/// [PullAwayFade];垂直拖拽三回调里先过闸(全屏/缩放态不启用;视频页同启)
/// 再喂 controller。水平翻页不受影响(垂直识别器只认纵向;Interactive
/// Viewer 缩放态由调用方闸掉)。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 提交阈值:拖拽距离(逻辑像素)与松手纵向速度,任一过线即提交返回。
const double kPullAwayCommitDistance = 110;
const double kPullAwayCommitVelocity = 700;

/// 下拉状态机:拖拽沿 update 累计跟手位移;松手不足阈值 [settleBack]
/// 弹回(easeOutCubic),过阈值由调用方直接 pop(位移冻结在释放位,
/// 航班以绘制位起飞)。
final class PullAwayController extends ChangeNotifier {
  PullAwayController({required TickerProvider vsync})
      : _settle = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: 220),
        ) {
    _settle.addListener(_onSettleTick);
  }

  static const Curve _settleCurve = Curves.easeOutCubic;
  final AnimationController _settle;
  Animation<Offset>? _settleAnim;
  double _dy = 0;

  /// 当前跟手位移(逻辑像素;向下为正)。
  double get dy => _dy;

  /// chrome 淡出进度(0 = 常显,1 = 全隐),按提交距离归一。
  double get progress =>
      (_dy / kPullAwayCommitDistance).clamp(0.0, 1.0);

  /// 拖拽开始:停掉在途弹回(新拖拽从当前位继续跟手)。
  void beginDrag() {
    _settle.stop();
  }

  /// 累计跟手位移(向下为正,负值钳 0)。
  void update(double dy) {
    final v = math.max(0.0, dy);
    if (v == _dy) return;
    _dy = v;
    notifyListeners();
  }

  /// 不足阈值:弹回复位(easeOutCubic)。
  void settleBack() {
    _settleAnim = _settle.drive(
      Tween<Offset>(
              begin: Offset(0, _dy), end: Offset.zero)
          .chain(CurveTween(curve: _settleCurve)),
    );
    _settle.forward(from: 0);
  }

  void _onSettleTick() {
    final anim = _settleAnim;
    if (anim == null) return;
    _dy = anim.value.dy;
    notifyListeners();
  }

  /// 复位(提交返回沿:位移冻结由路由销毁收尾,调用方无需再动)。
  void reset() {
    _settle.stop();
    _settleAnim = null;
    if (_dy == 0) return;
    _dy = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _settle
      ..stop()
      ..dispose();
    super.dispose();
  }
}

/// 跟手变换:图片页内容随 [PullAwayController] 平移 + 轻微缩小。
/// 缩小走**布局**(SizedBox,hero 实测盒随之,航班起点 = 可见位);
/// 平移走绘制(Transform.translate,不扰动布局)。**结构恒定**:闲态
/// 也走同一包裹链(恒等值)—— 闲态直通会在拖拽起步沿整棵子树跨结构
/// 重挂载,视频页播放器平台视图卸载重装 = 闪一下 + 播放位丢失
/// (真机复报「视频下滑跟手返回会闪一下」根因)。
class PullAwayTransform extends StatelessWidget {
  const PullAwayTransform({
    super.key,
    required this.controller,
    required this.child,
  });

  final PullAwayController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final dy = controller.dy;
        // 缩小幅度:提交距离后仍缓续(封顶 12%),读感与 iOS 对齐;
        // 闲态 shrink=1 → 盒同全尺寸,布局恒等。
        final shrink =
            1 - 0.12 * (dy / (kPullAwayCommitDistance * 2)).clamp(0.0, 1.0);
        return LayoutBuilder(
          builder: (context, cons) {
            return Align(
              child: SizedBox(
                width: cons.maxWidth * shrink,
                height: cons.maxHeight * shrink,
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: child,
                ),
              ),
            );
          },
        );
      },
      child: child,
    );
  }
}

/// chrome 淡出:appBar/底栏随下拉进度渐隐(松手弹回即复显;提交沿
/// 随路由淡出收尾)。
class PullAwayFade extends StatelessWidget {
  const PullAwayFade({super.key, required this.controller, required this.child});

  final PullAwayController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) => Opacity(
        opacity: 1 - controller.progress,
        child: child!,
      ),
      child: child,
    );
  }
}
