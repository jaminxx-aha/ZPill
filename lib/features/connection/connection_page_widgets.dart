part of 'connection_page.dart';

class _MethodHero extends StatefulWidget {
  const _MethodHero({
    required this.method,
    required this.busy,
    this.ready = false,
    this.onTap,
  });

  final ConnectionMethod method;

  /// 连接在途(驱动涟漪;false 沿即停即回位)。
  final bool busy;

  /// 已连接(十轮引入,十一轮定样:仅蓝牙页用 —— 连接后页面不跳转,
  /// hero 转**实底统一黄** [AppColors.accentYellow] + [AppColors.
  /// onBrandYellow] 深字图标,与按钮实底同深;十轮的淡绿被否。busy
  /// 优先 —— 在途黄描边+涟漪)。
  final bool ready;

  /// 点按(USB/AP = 连接/取消;STA/蓝牙 = 连最近/取消;null = 纯展示)。
  final VoidCallback? onTap;

  @override
  State<_MethodHero> createState() => _MethodHeroState();
}

class _MethodHeroState extends State<_MethodHero>
    with SingleTickerProviderStateMixin {
  static const double _circle = 96;
  static const int _ringCount = 3;

  /// 九轮「圈小一点,速度慢一点」:外扩上限 1.9→1.5、周期 1500→2400ms
  ///(一圈的可见寿命 = 整周期,错相 1/3 不变)。
  static const double _ringMaxScale = 1.5;
  static const Duration _ringPeriod = Duration(milliseconds: 2400);

  /// 涟漪驱动。**initState 现建,不做内联惰性初始化** —— 闲态 hero 终生
  /// 不碰涟漪,首次访问落在 dispose 沿:unmount 期 createTicker 查
  /// TickerMode 祖先必炸(debug 守卫「deactivated widget's ancestor」,
  /// f82e8eb 起全量 app 骨架类用例全挂的根因)。
  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(vsync: this, duration: _ringPeriod);
    if (widget.busy) _ripple.repeat();
  }

  @override
  void didUpdateWidget(covariant _MethodHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy == oldWidget.busy) return;
    if (widget.busy) {
      _ripple.repeat();
    } else {
      _ripple
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  /// 一圈涟漪(进度 0→1:自圆缘外扩 + 淡出;easeOutCubic 外扩减速)。
  Widget _ring(double progress) {
    final scale =
        1.0 + (_ringMaxScale - 1.0) * Curves.easeOutCubic.transform(progress);
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: (1 - progress) * 0.5,
        child: Container(
          width: _circle,
          height: _circle,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accentYellow, width: 2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 外层 96×96 不变(命中区 = 圆);涟漪环经 Clip.none 溢出绘制,
    // 溢出区不吃点按(盒外 hitTest 不达)。
    return SizedBox(
      width: _circle,
      height: _circle,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (widget.busy)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) => Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < _ringCount; i++)
                      _ring((_ripple.value + i / _ringCount) % 1.0),
                  ],
                ),
              ),
            ),
          InkWell(
            key: const ValueKey('conn_method_hero'),
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _circle,
              height: _circle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 十一轮:蓝牙就绪 = 实底统一黄(与按钮实底同深,配
                // onBrandYellow 深字;十轮淡绿被否);在途黄描边优先。
                color: widget.ready && !widget.busy
                    ? AppColors.accentYellow
                    : theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.45),
                border: Border.all(
                    color: widget.busy || widget.ready
                        ? AppColors.accentYellow
                        : theme.colorScheme.outlineVariant),
              ),
              child: Center(
                child: _ConnectionPageState._methodIconWidget(widget.method,
                    size: 44,
                    color: widget.ready && !widget.busy
                        ? AppColors.onBrandYellow
                        : theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// STA 扫描视图体(2026-10-19 改版):进方式即自动扫描(静默 —— 无
/// 扫描钮、无「扫描中」指示,2026-10-19 用户定稿),离方式停扫
/// (dispose);内容 = 状态行 + 固定错误位 + Wi-Fi hero(**八轮可点 =
/// 连最近**)+「已配对 / 其它设备」两段列表;当前方式在 AppBar 方式位
/// (六轮)。已配对行 = 档案最近优先,首条带绿底「最近」徽(八轮);
/// 连接由行点按或 hero 点按触发;取消 = 再点 hero(connecting/
/// reconnecting 在途点按即断,与 USB/AP 同语义 —— 九轮底部「取消
/// 连接」按钮退役)。没有路由可退(原地替换),状态行在视图顶部。
class _StaScanBody extends StatefulWidget {
  const _StaScanBody({required this.controller, required this.page});

  final ConnectionController controller;

  /// 宿主页 State(hero/提示卡/状态表现等页内件复用;同库私有可达)。
  final _ConnectionPageState page;

  @override
  State<_StaScanBody> createState() => _StaScanBodyState();
}

class _StaScanBodyState extends State<_StaScanBody> {
  @override
  void initState() {
    super.initState();
    // 帧尾起扫:initState 在 build 期,同步 startScan 会同步 notify,
    // 炸 ListenableBuilder 的「build 期 markNeedsBuild」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.controller.startScan());
      }
    });
  }

  @override
  void dispose() {
    // 离开 STA 视图停扫(扫描只在本页面存续期运行,2026-10-19 定稿;
    // 切到其它方式页同样不经此体,不触发扫描)。
    if (widget.controller.scanning) {
      unawaited(widget.controller.stopScan());
    }
    super.dispose();
  }

  /// 「其它设备」列示源:mDNS 发现里滤掉已配对相机(2026-10-21 用户
  /// 定稿,与 BLE 面板同款)—— 匹配 = 归一化名相等(两侧都是 mDNS 实
  /// 例名)或 host == lastIp(最强信号)。
  List<DiscoveredIpCamera> _othersIpCameras(ConnectionController controller) {
    bool paired(DiscoveredIpCamera c) => controller.savedCameras.any((s) {
          String norm(String v) =>
              v.replaceAll(RegExp(r'[\s_]+'), '').toLowerCase();
          if (s.lastIp != null && s.lastIp == c.host) return true;
          return s.name.isNotEmpty &&
              c.name.isNotEmpty &&
              norm(s.name) == norm(c.name);
        });
    return controller.cameras.where((c) => !paired(c)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final busy = _ConnectionPageState._busyState(controller);
        final (label, dot, busySpin) =
            _ConnectionPageState._ptpStatusPresentation(controller, context);
        // 图标坐标恒定(见 _ConnectionPageState._heroTopGap,四方式
        // 同位);四轮裁定「配对信息往上移」:两段列表紧随图标之下,
        // 剩余空间全在底部(内容短则留白,长则区内滚动)。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppSpacing.screenPadding,
              child: ConnStatusHeader(
                  dotColor: dot, label: context.t(label), busy: busySpin),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: ConnErrorSlot(
                hint: controller.hint?.key,
                args: controller.hint?.args,
                error: controller.state == CameraLinkState.failed,
              ),
            ),
            const SizedBox(height: _ConnectionPageState._heroTopGap),
            Center(
              child: _MethodHero(
                method: ConnectionMethod.sta,
                busy: busy,
                // 八轮:图标即连接钮 —— 连最近(档案首条),在途点按
                // 取消(与 USB/AP hero 同语义)。
                onTap: () => widget.page._heroPressed(controller),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: AppSpacing.screenPadding.copyWith(top: AppSpacing.md),
                children: [
                  // 已配对:paired_cameras.json 快连档案(最近优先,点行
                  // 连接,忘记 = 清档案 + 配对过的换新身份 → 全新配对,
                  // 无感)。首条 = 最近连接条目,名后带绿底「最近」徽
                  //(八轮;hero 点按连的就是它)。
                  const ConnSectionHeader(label: 'conn.sectionPaired'),
                  ConnTileGroup(
                    children: [
                      if (controller.savedCameras.isEmpty)
                        const _EmptyGroupRow(text: 'conn.noPairedDevices')
                      else
                        for (final (i, saved)
                            in controller.savedCameras.indexed)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.photo_camera_outlined),
                            title: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: Text(saved.name)),
                                if (i == 0) ...[
                                  const SizedBox(width: AppSpacing.sm),
                                  const ConnRecentBadge(),
                                ],
                              ],
                            ),
                            subtitle: saved.lastIp == null
                                ? null
                                : Text(saved.lastIp!),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: context.t('conn.forgetCamera'),
                              onPressed: busy
                                  ? null
                                  : () =>
                                      _ConnectionPageState._confirmRemoveSaved(
                                          context, controller, saved),
                            ),
                            onTap: busy
                                ? null
                                : () =>
                                    unawaited(controller.connectSaved(saved)),
                          ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 其它设备:mDNS 发现(点行连接),已配对相机滤除不重复
                  // 列示(2026-10-21 用户定稿,与 BLE 面板同款)。扫描静默
                  // —— 无「扫描中」指示,结果静默入列;相机须停留在「等
                  // 待连接」画面等解释收进 hero 说明(点图标弹说明弹窗)。
                  const ConnSectionHeader(label: 'conn.sectionOthers'),
                  ConnTileGroup(
                    children: [
                      if (_othersIpCameras(controller).isEmpty)
                        const _EmptyGroupRow(text: 'conn.noOtherDevices')
                      else
                        for (final camera in _othersIpCameras(controller))
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.photo_camera_outlined),
                            title: Text(camera.name),
                            subtitle: Text(camera.host),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: busy
                                ? null
                                : () => unawaited(
                                    controller.connectDiscovered(camera)),
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 列表组空态行(组容器内居中次级小字;text 即 t() 键)。
class _EmptyGroupRow extends StatelessWidget {
  const _EmptyGroupRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      child: Center(
        child: Text(
          context.t(text),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
