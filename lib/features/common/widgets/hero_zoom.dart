/// 「网格格 → 查看器」一镜到底转场(通用件,系统图库(iOS 图库/
/// HarmonyOS 图库)同式):相机相册与图库两对「网格 ↔ 查看器」同用;
/// 任何「格 → 详情」对按三步接入 —— 格侧包 [HeroZoom]、详情初始页以
/// `aspectBox: true` 包图片显示盒、推入走 [ZoomPageRoute]。
///
/// 机制(与原生对齐、与框架约定同构)的三个关键:
/// ① **查看器侧 hero 盒 = 图片显示位**([HeroZoom] 的 `aspectBox` 档用
///    `AspectRatio` 按图比定盒,盒由布局保证 = 图片 contain 显示位):
///    框架对航班矩形有 origin 追踪约定(_HeroFlight.onTick 每帧把终点
///    原点改写为 toHero 盒实测原点、只继承尺寸)—— 终点若「盒内居中」
///    会被逐帧改写回盒左上角,落点偏移、收梭子时图片再挪一下(真机
///    实证)。hero 盒=显示位后,框架默认的「格位 → 显示位」矩形变形
///    即原生观感,无需自定义补间;梭子([heroZoomShuttle])只是一张
///    cover 铺满行程 rect 的图,裁切窗随 rect 比变形连续打开。
/// ② **被覆盖页原地不动**(ZoomPageRoute 的 delegatedTransition 恒等,
///    参考工程 DIALOG 模式语义):网格不缩退不快隐,只被浮出的黑底渐盖。
/// ③ **弹簧手感**:推/收都是高初速出发、减速落定([kHeroZoomCurve] =
///    easeOutCubic,回程框架 reverseCurve 自动倒放),路由淡入与航班
///    同曲线同拍;时长 [kHeroZoomDuration]/[kHeroZoomReverseDuration]。
///
/// 图源两侧同源(格缩略盘档路径):300px 档与格内 Image 共用解码缓存
/// ([gridThumbImageProvider]),航班首帧零解码零闪烁;全解档叠在其上,
/// 推程落点/回程起点都是清图收尾。
///
/// 降级:图比未解析(缓存未命中,罕见)时 `aspectBox` 档回落普通盒
/// (hero 盒 = 子树自身排版,航班终点随之);缩略未就绪(取数在途/
/// 失败)任一侧不挂 Hero,配对不成 = 无航班,推入照旧走 [ZoomPageRoute]
/// 淡入淡出(框架对无配对 Hero 原样处理,无副作用)。
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// 动效曲线与时长:路由淡入淡出与 Hero 航班同源同相(曲线分家则底图
/// 与飞行图错拍)。easeOutCubic = 高初速(起速 ≈ 均速 3 倍)减速落定,
/// 即系统图库弹簧手感的定程近似;回程框架以 reverseCurve(=flipped)
/// 倒放 —— 出发快、落格软。
const Curve kHeroZoomCurve = Curves.easeOutCubic;
const Duration kHeroZoomDuration = Duration(milliseconds: 350);
const Duration kHeroZoomReverseDuration = Duration(milliseconds: 300);

/// 航班路径两线(尺寸先行、中心拖尾):梭子拿到的 t 已含航班缓动
///(Hero.curve),尺寸恒等跟随(原生缩放读感),中心以 [kHeroZoomCenterCurve]
/// 拖尾 —— 框架默认补间中心/尺寸同插,偏离中线的格读成「边漂边缩」
///(真机:角格不自然、中格尚可);中心拖尾即原生「自格位长出」的读感。
/// 回程同补间反放(t 1→0),即原生回放的对称观感。**勿在补间内再对 t
/// 施加航班曲线**(双重缓动,v6 真机角格起步过冲实测)。
const Curve kHeroZoomCenterCurve = Curves.easeIn;

/// 格缩略的 300px 图像缓存键提供器:与 `Image.file(cacheWidth: 300)`
/// 同构(ResizeImage(FileImage, width: 300))—— 格内 Image 用本函数
/// 构造后,航班梭子必然命中同一份已解码缓存。
ImageProvider<Object> gridThumbImageProvider(String path) =>
    ResizeImage(FileImage(File(path)), width: 300);

/// 航班图源数据([HeroZoom] 外围继承件):梭子经 context 从任一侧取
/// 盘档路径自建图源(两侧同值,任取其一)。
class HeroZoomData extends InheritedWidget {
  const HeroZoomData({super.key, required this.thumbPath, required super.child});

  /// 格缩略盘档路径(配对两侧同值)。
  final String thumbPath;

  static HeroZoomData? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HeroZoomData>();

  @override
  bool updateShouldNotify(HeroZoomData oldWidget) =>
      thumbPath != oldWidget.thumbPath;
}

/// 航班梭子(flightShuttleBuilder):一张 cover 铺满行程 rect 的图
///(双档:300px 缓存命中先显、全解档就位后覆盖)。行程 rect 从格位
///(cover 裁切)连续变形到图片显示位(等比全览),cover 的裁切窗随
/// rect 比变形连续打开 —— t=0 恰为格观感、t=1 恰为查看器观感。图档
/// 缺失层静默收缩(errorBuilder 收口,不进错误道)。
Widget heroZoomShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final path = (HeroZoomData.of(fromHeroContext) ??
          HeroZoomData.of(toHeroContext))!
      .thumbPath;
  return Stack(
    fit: StackFit.expand,
    children: [
      Image(
        image: gridThumbImageProvider(path),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: _silent,
      ),
      Image(
        image: FileImage(File(path)),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: _silent,
      ),
    ],
  );
}

/// 图档缺失层的静默收缩(解码失败不报错误道,该层不画)。
Widget _silent(BuildContext context, Object error, StackTrace? stackTrace) =>
    const SizedBox.shrink();

/// 航班路径补间:只重塑中间路径 —— 尺寸/中心两线解耦(见
/// [kHeroZoomSizeCurve]);起点/终点仍为框架实测原值,与
/// `_HeroFlight.onTick` 的 origin 追踪约定相容(终点 topLeft == toHero
/// 盒原点,逐帧比对不变,不触发重测)。
class _ZoomPathTween extends RectTween {
  _ZoomPathTween({required super.begin, required super.end});

  @override
  Rect lerp(double t) {
    final b = begin!;
    final e = end!;
    // t 已是缓动后进度(Hero.curve):尺寸恒等,中心拖尾(easeIn)。
    final size = Size.lerp(b.size, e.size, t)!;
    final center = Offset.lerp(
        b.center, e.center, kHeroZoomCenterCurve.transform(t))!;
    return Rect.fromCenter(
        center: center, width: size.width, height: size.height);
  }
}

/// 配对 Hero(格侧与查看器初始页同款):[tag] 两侧一致,[thumbPath] 为
/// 格缩略盘档路径(两侧同值)。曲线随 [kHeroZoomCurve](与路由淡入淡出
/// 同源同拍)。不可嵌套(框架 assert Hero 内不得再有 Hero;本件只包页
/// 面内容,互为兄弟)。
///
/// [aspectBox](查看器初始页开):按图比用 [AspectRatio] 定盒再包 Hero
/// —— 盒即图片显示位,框架默认矩形变形的终点自然落在真实排版位上
///(见库注 ①)。图比自 300px 档解析(查看器侧构建沿缓存命中同步回,
/// 零额外解码;同步回沿落在 initState 内,setState 直接生效于同帧
/// build);[deSqueeze] 为变宽还原倍率(显示比 = 图比 × 倍率,与
/// DeSqueezedImage 同口径)。图比未解析时回落普通盒(航班终点 = 子树
/// 自身排版位)。
class HeroZoom extends StatefulWidget {
  const HeroZoom({
    super.key,
    required this.tag,
    required this.thumbPath,
    required this.child,
    this.aspectBox = false,
    this.deSqueeze = 1.0,
  });

  final Object tag;

  /// 格缩略盘档路径(配对两侧同值;梭子图源与显示盒图比由此自建)。
  final String thumbPath;

  final Widget child;

  /// 按图比定显示盒(查看器初始页开;格侧关 —— 格受紧约束,盒即格)。
  final bool aspectBox;

  /// 变宽还原倍率(与 DeSqueezedImage 同口径;1.0 = 关)。
  final double deSqueeze;

  @override
  State<HeroZoom> createState() => _HeroZoomState();
}

class _HeroZoomState extends State<HeroZoom> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;

  @override
  void initState() {
    super.initState();
    if (!widget.aspectBox) return; // 格侧不需要图比(盒 = 格,紧约束)
    _resolveAspect();
  }

  @override
  void didUpdateWidget(HeroZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 格复用换图(渐进配对 NEF→JPG 等):路径变更重解析图比。
    if (widget.thumbPath != oldWidget.thumbPath ||
        widget.deSqueeze != oldWidget.deSqueeze) {
      _aspect = null;
      if (widget.aspectBox) _resolveAspect();
    }
  }

  void _resolveAspect() {
    _removeListener();
    final stream = gridThumbImageProvider(widget.thumbPath)
        .resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (mounted && info.image.width > 0) {
        setState(() => _aspect = info.image.width / info.image.height);
      }
    }, onError: (Object _, StackTrace? __) {});
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _removeListener() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect;
    Widget hero = HeroZoomData(
      thumbPath: widget.thumbPath,
      child: Hero(
        tag: widget.tag,
        curve: kHeroZoomCurve,
        flightShuttleBuilder: heroZoomShuttle,
        createRectTween: (Rect? begin, Rect? end) =>
            _ZoomPathTween(begin: begin, end: end),
        child: widget.child,
      ),
    );
    if (widget.aspectBox && aspect != null) {
      hero = AspectRatio(
        aspectRatio: aspect * widget.deSqueeze,
        child: hero,
      );
    }
    return hero;
  }
}

/// 查看器开合路由(一镜到底的「页面壳」):整页淡入/淡出(黑底原地
/// 浮现/退去,无位移无缩放),被覆盖页委托为**原地不动**
/// ([delegatedTransition] 恒等,只作用于这一对路由 —— 系统 zoom 转场
/// 会把被覆盖页缩退快隐,与飞行图叠加显生硬;原生图库里网格是不动的,
/// 只被浮出的黑底渐盖)。时长/曲线与 Hero 航班同源([kHeroZoomCurve]/
/// [kHeroZoomDuration]/[kHeroZoomReverseDuration]),底图与图飞同拍。
class ZoomPageRoute<T> extends PageRouteBuilder<T> {
  ZoomPageRoute({required super.pageBuilder})
      : super(
          transitionDuration: kHeroZoomDuration,
          reverseTransitionDuration: kHeroZoomReverseDuration,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // 与航班同曲线(回程框架自动用 flipped,与 Hero 的
            // reverseCurve 语义一致):淡入淡出与 rect 航班同拍。
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: kHeroZoomCurve,
                reverseCurve: kHeroZoomCurve.flipped,
              ),
              child: child,
            );
          },
        );

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          child;
}
