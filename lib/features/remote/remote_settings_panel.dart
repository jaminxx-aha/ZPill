import 'package:flutter/material.dart';

import '../../data/settings_store.dart';
import '../../l10n/l10n.dart';
import '../edit/lut_presets.dart';
import 'live_design.dart';
import 'monitor_toggles.dart';
import 'remote_capture_strip.dart';
import 'remote_controller.dart';
import 'shooting_param_catalog.dart';

/// 拍摄设置浮层(2026-10-10 iPhone 相机式重排:控制行「设置」钮的非
/// 模态玻璃浮层,竖屏底锚居中/横屏让位右缘快门柱;吸收原「监看辅助」
/// 浮层 —— tune 钮由胶囊/顶栏移到控制行):四段 —— ①拍摄参数(全
/// 目录 tile,点按走 [onEditParam] → 参数编辑底单;2026-10-12 竖屏
/// 读出行与横屏左参数栏先后删除后成为唯一参数入口)②对焦
/// (2026-10-12 自对焦浮层迁入:MF 步进/拉焦轮 —— 快门旁对焦钮已瘦身
/// 为一键 AF)③监看开关(取景/网格/斑马纹/直方图/水平仪/伪色/峰值;
/// 2026-10-12 十二轮起全部持久化 —— 关掉重进拍摄页保持,取景开关
/// 同款)④辅助芯片(对焦后拍/SDRAM 直拍/AE-L/自拍/APP 接管)。
/// 2026-10-17 排版收口:四段统一排印 —— 参数/监看区等宽格子网格
/// ([_CellGrid])、控件形态统一图标盒([_iconBoxTile],示波器/遮幅/
/// 主体追踪原文字胶囊与图标盒混排)、选项组标签上行([_optionRow],
/// 窄面板换行孤儿芯片)、段头 hairline 分隔。[maxHeight] 限高内滚
/// (竖屏约 0.55 屏高,横屏顶栏与底条之间);点取景画面或再点设置钮
/// 即收(见 RemotePage);状态随控制器 + [toggles](持久化设置桥接),
/// 监听由外层 AnimatedBuilder 驱动。
class CaptureSettingsPanel extends StatelessWidget {
  const CaptureSettingsPanel({
    super.key,
    required this.controller,
    required this.toggles,
    required this.activeParam,
    required this.onEditParam,
    required this.onTogglesChanged,
    required this.onLiveViewToggle,
    required this.onTakeoverRequest,
    required this.onLiveViewQualityChanged,
    required this.onSdramCaptureChanged,
    required this.onBleGpsInjectChanged,
    required this.onVolumeKeyShutterChanged,
    this.bleGpsInject = false,
    this.bleReady = false,
    this.volumeKeyShutter = false,
    this.volumeKeyShutterAvailable = false,
    this.liveViewImageSize,
    this.liveViewImageCompression,
    this.maxHeight,
  });

  final RemoteController controller;
  final MonitorToggles toggles;

  /// 当前打开编辑底单的参数码(金高亮 tile,读出条同款联动)。
  final int? activeParam;

  final void Function(BuildContext context, ShootingParam param) onEditParam;
  final void Function(MonitorToggles toggles) onTogglesChanged;

  /// 取景开关落定(十二轮「取景器关闭的开关」):true = 起景,false =
  /// 停景(0x9202),连同持久化由页面侧 [_setLiveView] 收口 —— 这里
  /// 只透传点按;录制中本浮层已禁点(快门停录走取景门)。
  final void Function(bool start) onLiveViewToggle;

  /// 取景画质档落定(2026-10-12 官方 §6.5.11.4-5):尺寸/压缩两档独立
  /// 选,null = 跟随相机;持久化与相机写入由页面侧收口。
  final void Function(int? imageSize, int? compression)
      onLiveViewQualityChanged;

  /// SDRAM 直拍落定(0x90CB 一体拍 + 0xC101 回传入图库):控制器即时
  /// 生效与持久化由页面侧收口(同取景画质)。
  final void Function(bool value) onSdramCaptureChanged;

  /// BLE GPS 注入落定(0x2007):开关写设置;会话起停/重连由
  /// AppServices 驱动收口。[bleReady] = BLE 会话就绪(未配对禁点)。
  final void Function(bool value) onBleGpsInjectChanged;
  final bool bleGpsInject;
  final bool bleReady;

  /// 音量键快门落定(Android/iOS 行):只写设置;原生开关沿
  /// (setEnabled 推/撤)由页面侧在接线沿收口。[volumeKeyShutterAvailable]
  /// = 平台门禁(Android/iOS 才 true;ohos 未做原生拦截,行不出现)。
  final void Function(bool value) onVolumeKeyShutterChanged;
  final bool volumeKeyShutter;
  final bool volumeKeyShutterAvailable;

  /// 当前画质档(持久化设置镜像;null = 跟随相机)。
  final int? liveViewImageSize;
  final int? liveViewImageCompression;

  final void Function(BuildContext context) onTakeoverRequest;

  /// 内容限高(null = 不限);超出内部滚动。
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final live = LiveDesign.of(context);
    final body = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(live, context.t('remote.paramsGroup'), first: true),
            // 参数区等宽格子(2026-10-17):旧变宽 Wrap 每行 4/6/4 参差、
            // 优化校准槽位真名等长值溢出裁切,格化后行行对齐。
            _CellGrid(
              rowHeight: 46,
              children: [
                for (final p in orderedCaptureParams(
                    videoMode: controller.cameraMode == CaptureMode.video))
                  captureParamTileOf(
                      context, controller, activeParam, onEditParam, p),
              ],
            ),
            _sectionHeader(live, context.t('remote.focusGroup')),
            _focusControls(context),
            _sectionHeader(live, context.t('common.monitoring')),
            _monitorToggles(context),
            _liveViewQualityRows(context),
            _sectionHeader(live, context.t('remote.assistGroup')),
            _assistChips(context),
          ],
        ),
      ),
    );
    return Container(
      constraints:
          maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      decoration: BoxDecoration(
        color: live.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: live.hairline),
      ),
      child: body,
    );
  }

  /// 段头(2026-10-17 加 hairline 分隔线:四段小字头挤在一面玻璃上
  /// 无结构,分隔后扫读有锚点;首段无线)。[first] = 面板首段。
  Widget _sectionHeader(LivePalette live, String label, {bool first = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!first) Container(height: 1, color: live.hairline),
          Padding(
            padding: EdgeInsets.only(top: first ? 2 : 10, bottom: 6),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: live.faint)),
          ),
        ],
      );

  /// 对焦控制组(2026-10-12 自对焦浮层迁入):MF 步进(0x9204 相对量,
  /// 近/远各一步)+ 拉焦轮开关(取景画面右缘竖条,开 = 金;重开清失败
  /// 预算 resetFocusDial,从可用态起步)+ 主体追踪。2026-10-17 控件
  /// 形态统一:四件全走图标盒(主体追踪原文字胶囊芯片同 Wrap 混排,
  /// 与图标盒基线不齐)。机身对焦模式为 MF 时全部灰化(机内马达脱开,
  /// 远程对焦失效 —— 只有镜头对焦环能动焦)+ 常驻提示行(盲按无响应
  /// 的困惑根源)。端点态(0xA00C 方向归因,近端/远端已到)另有常驻
  /// 提示行,反向驱动即解锁。
  Widget _focusControls(BuildContext context) {
    final live = LiveDesign.of(context);
    final usable = controller.linkUp &&
        controller.liveViewActive &&
        !controller.focusModeIsMf;
    final dialOn = toggles.focusDial;
    // 主体追踪(0x9424/0x9425):门控 = 取景在 + 非 MF + AF 区域「自动」
    // (0x8011;读控制器实时值);追踪进行中保持可点(停止优先于门控)。
    final trackUsable = usable && controller.afAreaCanTrack;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CellGrid(
          rowHeight: kPanelIconRowHeight,
          columns: 4,
          children: [
            _iconBoxTile(
              context,
              icon: Icons.remove,
              label: context.t('remote.mfNear'),
              enabled: usable,
              onTap: () => controller.mfDriveStep(towardNear: true),
              tooltip: context.t('remote.mfNearStep'),
            ),
            _iconBoxTile(
              context,
              icon: Icons.add,
              label: context.t('remote.mfFar'),
              enabled: usable,
              onTap: () => controller.mfDriveStep(towardNear: false),
              tooltip: context.t('remote.mfFarStep'),
            ),
            _iconBoxTile(
              context,
              icon: Icons.vertical_align_center,
              label: context.t('remote.focusDial'),
              selected: dialOn,
              onTap: () {
                if (!dialOn) controller.resetFocusDial();
                onTogglesChanged(toggles.copyWith(focusDial: !dialOn));
              },
            ),
            _iconBoxTile(
              context,
              icon: Icons.person_search,
              label: context.t('remote.subjectTracking'),
              selected: controller.tracking,
              enabled: controller.tracking || trackUsable,
              onTap: controller.tracking
                  ? controller.endTracking
                  : controller.startTracking,
              tooltip: context.t('remote.subjectTrackingHint'),
            ),
          ],
        ),
        if (controller.focusModeIsMf) ...[
          const SizedBox(height: 6),
          Text(context.t('remote.mfDisabled'),
              style: TextStyle(fontSize: 10, color: live.muted)),
        ] else if (controller.mfNearEnd || controller.mfFarEnd) ...[
          // 端点态常驻行(0xA00C 按请求方向归因,RemoteController
          // .mfNearEnd/mfFarEnd):反向驱动一步即解锁(轮锁同步解除)。
          const SizedBox(height: 6),
          Text(
              context.t(controller.mfNearEnd
                  ? 'remote.nearLimitUnlock'
                  : 'remote.farLimitUnlock'),
              style: TextStyle(fontSize: 10, color: live.muted)),
        ] else if (usable && !controller.afAreaCanTrack) ...[
          const SizedBox(height: 6),
          Text(context.t('remote.trackingNeedsAuto'),
              style: TextStyle(fontSize: 10, color: live.muted)),
        ],
      ],
    );
  }

  /// 监看开关组(原辅助浮层迁移,拉焦轮除外 —— 在上方对焦段):取景
  /// 打头(十二轮总开关,当前态跟 liveViewActive,录制中禁点 —— 视频
  /// 模式停录门依赖取景在跑);网格等走 [toggles]。斑马纹/直方图/伪色/
  /// 峰值/示波器族共享一份帧分析 —— 开关落定后由页面同步
  /// RemoteController.analyzer 启停(见 RemotePage._syncAnalyzerEnabled)。
  /// 2026-10-17 控件形态统一:示波器/遮幅两个循环件原文字胶囊芯片与
  /// 图标盒同 Wrap 混排基线不齐,改同款图标盒(标签带当前档),12 件
  /// 进等宽格子网格 —— 与参数区同一套排印。
  Widget _monitorToggles(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CellGrid(
          rowHeight: kPanelIconRowHeight,
          children: [
            // 取景总开关(十二轮「取景器关闭的开关」):当前态跟
            // liveViewActive(起景失败/引擎态即时可见,不跟持久位);录制中
            // 禁点 —— 视频模式停录门依赖取景在跑。
            _iconBoxTile(context,
                icon: Icons.videocam_outlined,
                label: context.t('remote.viewfinderGroup'),
                selected: controller.liveViewActive,
                enabled: !controller.recording,
                onTap: () => onLiveViewToggle(!controller.liveViewActive)),
            _iconBoxTile(context,
                icon: Icons.grid_on,
                label: context.t('remote.grids'),
                selected: toggles.grid,
                onTap: () =>
                    onTogglesChanged(toggles.copyWith(grid: !toggles.grid))),
            _iconBoxTile(context,
                icon: Icons.warning_amber,
                label: context.t('remote.zebra'),
                selected: toggles.zebra,
                onTap: () =>
                    onTogglesChanged(toggles.copyWith(zebra: !toggles.zebra))),
            _iconBoxTile(context,
                icon: Icons.bar_chart,
                label: context.t('remote.histogram'),
                selected: toggles.histogram,
                onTap: () => onTogglesChanged(
                    toggles.copyWith(histogram: !toggles.histogram))),
            _iconBoxTile(context,
                icon: Icons.linear_scale,
                label: context.t('remote.level'),
                selected: toggles.level,
                onTap: () =>
                    onTogglesChanged(toggles.copyWith(level: !toggles.level))),
            _iconBoxTile(context,
                icon: Icons.palette_outlined,
                label: context.t('remote.falseColor'),
                selected: toggles.falseColor,
                onTap: () => onTogglesChanged(
                    toggles.copyWith(falseColor: !toggles.falseColor))),
            _iconBoxTile(context,
                icon: Icons.blur_on,
                label: context.t('remote.peaking'),
                selected: toggles.peaking,
                onTap: () => onTogglesChanged(
                    toggles.copyWith(peaking: !toggles.peaking))),
            // 示波器族(帧分析路):循环切档 关→波形→RGB Parade→矢量→
            // 红绿灯(遮幅同款循环);开关落定由页面同步分析器启停。
            _iconBoxTile(context,
                icon: Icons.show_chart,
                label: switch (toggles.scope) {
                  ScopeKind.off => context.t('remote.scope'),
                  ScopeKind.waveform => context.t('remote.waveform'),
                  ScopeKind.parade => context.t('remote.scopeParade'),
                  ScopeKind.vector => context.t('remote.vector'),
                  ScopeKind.traffic => context.t('remote.trafficLights'),
                },
                selected: toggles.scope != ScopeKind.off,
                onTap: () => onTogglesChanged(
                    toggles.copyWith(scope: toggles.scope.next)),
                tooltip: context.t('remote.scopeCycle')),
            // 构图框三件(纯显示层,不占分析器):遮幅循环 + 安全框 +
            // 中心标。
            _iconBoxTile(context,
                icon: Icons.crop_16_9,
                // framingAspect.label 是画幅比数字串(「2.39」等),无需翻译。
                label: toggles.framingAspect == FramingAspect.off
                    ? context.t('remote.matte')
                    : context.t('remote.matteValue',
                        {'v': toggles.framingAspect.label}),
                selected: toggles.framingAspect != FramingAspect.off,
                onTap: () => onTogglesChanged(toggles
                    .copyWith(framingAspect: toggles.framingAspect.next)),
                tooltip: context.t('remote.matteCycle')),
            _iconBoxTile(context,
                icon: Icons.crop_free,
                label: context.t('remote.safeArea'),
                selected: toggles.framingSafeArea,
                onTap: () => onTogglesChanged(
                    toggles.copyWith(framingSafeArea: !toggles.framingSafeArea))),
            _iconBoxTile(context,
                icon: Icons.center_focus_weak,
                label: context.t('remote.centerMark'),
                selected: toggles.framingCenterMark,
                onTap: () => onTogglesChanged(toggles
                    .copyWith(framingCenterMark: !toggles.framingCenterMark))),
            // 内屏强关(0x9422,B 组线上未验):乐观态会话级,tooltip 标
            // 实验性(副作用未知,断流由看门狗兜底)。
            _iconBoxTile(context,
                icon: Icons.mobile_off,
                label: context.t('remote.rearScreen'),
                selected: controller.monitorOff,
                enabled: controller.linkUp,
                onTap: controller.toggleMonitorOff,
                tooltip: context.t('remote.rearScreenHint')),
          ],
        ),
        const SizedBox(height: 4),
        _monitorLutRow(context),
        // 示波器刻度行:波形/Parade 档才出现(矢量/红绿灯不吃 Y 轴刻度)。
        if (toggles.scope == ScopeKind.waveform ||
            toggles.scope == ScopeKind.parade) ...[
          const SizedBox(height: 4),
          _scopeOptionRows(context),
        ],
        // 峰值选项行:峰值开着才出现(关了藏行,少占面板高)。
        if (toggles.peaking) ...[
          const SizedBox(height: 4),
          _peakingOptionRows(context),
        ],
      ],
    );
  }

  /// 示波器 Y 轴刻度行:全幅(均分网格,旧观感)/ N-Log(legal-range
  /// 64-940 码 ↔ 0-100 IRE 刻度 + 18% 灰线,数学见 core/remote/
  /// scopes.dart)。**手动档常闭**:相机 N-Log 态(0xD0BB)不推事件须
  /// 轮询,自动跟随留账;波形/Parade 消费,矢量/红绿灯无 Y 轴不吃。
  Widget _scopeOptionRows(BuildContext context) {
    return _optionRow(
      context,
      context.t('remote.scopeScale'),
      tooltip: context.t('remote.nlogScale'),
      chips: _optionChips(
        context,
        const [('remote.fullRange', false), ('remote.scopeNlog', true)],
        toggles.scopeNLog,
        (v) => onTogglesChanged(toggles.copyWith(scopeNLog: v)),
      ),
    );
  }

  /// 监看 LUT 芯片行(内置风格表,纯显示层调色;选中即走高质量渲染
  /// 管线 —— 查表只在 shader 路径,设备不支持时无 LUT 画面照常)。
  Widget _monitorLutRow(BuildContext context) {
    return _optionRow(
      context,
      context.t('remote.monitorLut'),
      tooltip: context.t('remote.monitorLutHint'),
      chips: [
        _smallChip(
          live: LiveDesign.of(context),
          label: context.t('common.offShort'),
          selected: toggles.lutIndex < 0,
          onTap: () => onTogglesChanged(toggles.copyWith(lutIndex: -1)),
        ),
        for (var i = 0; i < builtinLuts.length; i++)
          _smallChip(
            live: LiveDesign.of(context),
            // LUT 标题(edit/lut_presets 的 builtinLuts 产出)原文即
            // t() 键,显示点包 t()。
            label: context.t(lutTitleKey(builtinLuts[i].title)),
            selected: toggles.lutIndex == i,
            onTap: () => onTogglesChanged(toggles.copyWith(lutIndex: i)),
          ),
      ],
    );
  }

  /// 峰值选项行(2026-10-14 灵敏度/颜色可配;2026-10-15 加算法档):
  /// 算法二选一(双尺度比值 = 默认,散景/失焦不亮,核见 core/remote/
  /// peaking_engines.dart;经典 = 单尺度梯度回退)+ 灵敏度三档
  /// (低/中/高:经典梯度阈值 24/40/64,双尺度参数见
  /// peakingDualScaleParamsOf,调优档非协议常量)+ 高亮色三档
  /// (金/白/红,取色在 live_view_overlays 的 peakingColorOf);
  /// 走 [onTogglesChanged] 持久化。
  Widget _peakingOptionRows(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _optionRow(
          context,
          context.t('remote.peakingEngine'),
          chips: _optionChips(
            context,
            const [('remote.dualScale', 0), ('remote.classic', 1)],
            toggles.peakingEngine,
            (v) => onTogglesChanged(toggles.copyWith(peakingEngine: v)),
          ),
        ),
        _optionRow(
          context,
          context.t('remote.peakingSens'),
          chips: _optionChips(
            context,
            const [('common.low', 0), ('common.medium', 1), ('common.high', 2)],
            toggles.peakingLevel,
            (v) => onTogglesChanged(toggles.copyWith(peakingLevel: v)),
          ),
        ),
        _optionRow(
          context,
          context.t('remote.peakingColor'),
          chips: _optionChips(
            context,
            const [('common.gold', 0), ('common.white', 1), ('common.red', 2)],
            toggles.peakingColor,
            (v) => onTogglesChanged(toggles.copyWith(peakingColor: v)),
          ),
        ),
      ],
    );
  }

  /// 取景画质行(2026-10-12 官方 §6.5.11.4-5):尺寸档决定 0x9428 帧
  /// 分辨率(QVGA 省流量 / XGA 提清晰度),压缩档决定 JPEG 质量;选值
  /// 即写相机(链路在)+ 持久化,「跟随」= 不写机身菜单既有值。
  Widget _liveViewQualityRows(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _optionRow(
          context,
          context.t('remote.vfSize'),
          chips: _optionChips<int?>(
            context,
            const [
              ('remote.follow', null),
              ('QVGA', 1),
              ('VGA', 2),
              ('XGA', 3),
            ],
            liveViewImageSize,
            (v) => onLiveViewQualityChanged(v, liveViewImageCompression),
          ),
        ),
        _optionRow(
          context,
          context.t('remote.vfQuality'),
          chips: _optionChips<int?>(
            context,
            const [
              ('remote.follow', null),
              ('remote.basicSize', 0),
              ('remote.basicQuality', 1),
              ('remote.normalSize', 2),
              ('remote.normalQuality', 3),
              ('remote.fineSize', 4),
              ('remote.fineQuality', 5),
            ],
            liveViewImageCompression,
            (v) => onLiveViewQualityChanged(liveViewImageSize, v),
          ),
        ),
      ],
    );
  }

  /// 辅助芯片组(原辅助浮层迁移):对焦后拍 / 自拍 / APP 接管。
  Widget _assistChips(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _smallChip(
          live: LiveDesign.of(context),
          label: context.t('remote.focusThenCapture'),
          selected: controller.focusBeforeCapture,
          onTap: () =>
              controller.focusBeforeCapture = !controller.focusBeforeCapture,
          tooltip: context.t('remote.focusThenCaptureHint'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: context.t('remote.sdramCapture'),
          selected: controller.sdramCapture,
          // 间隔拍摄运行中:SDRAM 直拍不可中途开(逐拍回传图库与调度轮
          // 冲突,也是启动互锁项)。
          onTap: controller.intervalActive
              ? null
              : () => onSdramCaptureChanged(!controller.sdramCapture),
          tooltip: context.t('remote.sdramHint'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: 'AE-L',
          selected: controller.aeLocked,
          onTap: !controller.linkUp ? null : controller.toggleAELock,
          tooltip: context.t('remote.aeAwbLockHint'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: 'GPS',
          selected: bleGpsInject,
          onTap: !bleReady ? null : () => onBleGpsInjectChanged(!bleGpsInject),
          tooltip: bleReady
              ? context.t('remote.bleGpsHint')
              : context.t('remote.bleNotPaired'),
        ),
        // Android/iOS 有原生实现才出行(ohos 未做拦截)。
        if (volumeKeyShutterAvailable)
          _smallChip(
            live: LiveDesign.of(context),
            label: context.t('remote.volumeShutter'),
            selected: volumeKeyShutter,
            onTap: () => onVolumeKeyShutterChanged(!volumeKeyShutter),
            tooltip: context.t(
              'remote.volumeShutterHint',
            ),
          ),
        Builder(
          // Builder 让 showMenu 锚到自拍芯片本身(而非整条浮层)。
          builder: (chipContext) => _smallChip(
            live: LiveDesign.of(chipContext),
            label: controller.selfTimerSeconds == 0
                ? context.t('remote.selfTimer')
                : context.t('remote.selfTimerValue', {'s': '${controller.selfTimerSeconds}'}),
            selected: controller.selfTimerSeconds > 0,
            // 间隔拍摄运行中:自拍让位(灰化)—— 定时 B 门/自拍倒计时
            // 与调度轮互相踩脚,先停轮再配。
            onTap: controller.intervalActive
                ? null
                : () => _pickSelfTimer(chipContext, controller),
            tooltip: context.t('remote.selfTimerHint'),
          ),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: controller.intervalActive
              ? context.t('interval.progress', {
                  'a': '${controller.intervalTaken}',
                  'b': controller.intervalShotCount == null
                      ? '∞'
                      : '${controller.intervalShotCount}'
                })
              : context.t('interval.title'),
          selected: controller.intervalActive,
          // 运行中点芯片 = 立即停轮(状态行同款停止,快捷入口);
          // 空闲点 = 参数底单(间隔/张数 → 开始)。
          onTap: controller.intervalActive
              ? controller.stopInterval
              : () => _pickInterval(context, controller),
          tooltip: context.t(
              'interval.tooltip'),
        ),
        _takeoverChip(context,
            controller: controller, onTakeoverRequest: onTakeoverRequest),
      ],
    );
  }
}

/// 图标盒行高(盒 34 + 2 + 标签 ~14):对焦/监看两格区共用。
const kPanelIconRowHeight = 52.0;

/// 等宽格子网格(2026-10-17 排版收口):旧变宽 Wrap(参数 tile 按内容
/// 自宽)每行 4/6/4 参差、长值溢出裁切;格化后每行 [columns] 列等宽、
/// 行高统一 [rowHeight],末行不齐以空格补齐保持对齐。[columns] 缺省
/// 按可用宽自适应(76pt 一列,3-4 列 —— 竖屏面板 ~309 内容宽出 4 列,
/// 横屏 300 出 3 列),对焦组定 4(四件一行是语义行,不随宽拆)。
class _CellGrid extends StatelessWidget {
  const _CellGrid({
    required this.rowHeight,
    required this.children,
    this.columns,
  });

  final double rowHeight;
  final List<Widget> children;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final cols = columns ?? (constraints.maxWidth / 76).floor().clamp(3, 4);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i += cols)
            Row(
              children: [
                for (var j = i; j < i + cols; j++)
                  Expanded(
                    child: j < children.length
                        ? SizedBox(height: rowHeight, child: children[j])
                        : const SizedBox(),
                  ),
              ],
            ),
        ],
      );
    });
  }
}

/// 图标盒 + 下标签(2026-10-17 控件形态统一):监看开关、示波器/遮幅
/// 循环件、MF 步进/焦点轮盘/主体追踪共用一套(旧形态混排 —— 文字
/// 胶囊芯片与图标盒同 Wrap,高低不齐;MF 盒独一份玻璃实底)。视觉盒
/// 40×34 不变:选中金盒金字,禁用灰化;标签纳入命中区(≥44 高)。
Widget _iconBoxTile(
  BuildContext context, {
  required IconData icon,
  required String label,
  bool selected = false,
  bool enabled = true,
  VoidCallback? onTap,
  String? tooltip,
}) {
  final live = LiveDesign.of(context);
  final box = SizedBox(
    width: 40,
    height: 34,
    child: Material(
      color: selected ? live.accentDim : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? live.accent.withValues(alpha: 0.5) : live.hairline,
        ),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Icon(icon,
            size: 18,
            color:
                !enabled ? live.faint : selected ? live.accent : live.muted),
      ),
    ),
  );
  return InkWell(
    onTap: enabled ? onTap : null,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        tooltip == null ? box : Tooltip(message: tooltip, child: box),
        const SizedBox(height: 2),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 10,
                color: !enabled
                    ? live.faint
                    : selected
                        ? live.accent
                        : live.faint)),
      ],
    ),
  );
}

/// 选项组行(2026-10-17 排版收口):标签独立一行 + 芯片行独立 Wrap —
/// 旧「标签+芯片」同行 Wrap 在窄面板换行时标签沉到行中、尾芯片成
/// 孤儿顶左缘(LUT 行 N-Log 还原),标签上行后换行从行首起,视觉有归着。
Widget _optionRow(
  BuildContext context,
  String label, {
  required List<Widget> chips,
  String? tooltip,
}) {
  final live = LiveDesign.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Tooltip(
        message: tooltip ?? label,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: live.faint)),
        ),
      ),
      const SizedBox(height: 3),
      Wrap(spacing: 4, runSpacing: 4, children: chips),
    ],
  );
}

/// 选项芯片列打包:(文案 t() 键, 值)表 + 当前值 + 落定回调。
List<Widget> _optionChips<T>(BuildContext context, List<(String, T)> options,
    T current, void Function(T) pick) {
  final live = LiveDesign.of(context);
  return [
    for (final option in options)
      _smallChip(
        live: live,
        // 选项文案经 t() 查目录,表外值(QVGA/VGA/XGA 等拉丁串)未命中
        // 原样回落。
        label: context.t(option.$1),
        selected: current == option.$2,
        onTap: () => pick(option.$2),
      ),
  ];
}

/// 浮层小芯片(对焦后拍 / 自拍 / APP 接管)。
Widget _smallChip({
  required LivePalette live,
  required String label,
  required bool selected,
  required VoidCallback? onTap,
  String? tooltip,
}) {
  final chip = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: selected ? live.accentDim : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color:
                selected ? live.accent.withValues(alpha: 0.5) : live.hairline),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 12, color: selected ? live.accent : live.muted),
          ),
        ),
      ),
    ),
  );
  return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
}

/// APP 接管控制状态芯片:未接管 = 点按弹确认启用;已接管 = 点按解除
/// (0x90C2 remote 模式;机身拨盘锁定,host 写入保值)。
Widget _takeoverChip(BuildContext context,
    {required RemoteController controller,
    required void Function(BuildContext) onTakeoverRequest}) {
  final live = LiveDesign.of(context);
  final active = controller.takeoverActive;
  return _smallChip(
    live: live,
    label: active ? context.t('takeover.active') : context.t('takeover.title'),
    selected: active,
    onTap: !controller.linkUp
        ? null
        : (active
            ? controller.releaseTakeover
            : () => onTakeoverRequest(context)),
    tooltip: context.t('takeover.hint'),
  );
}

/// 自拍档位点选(芯片 → 菜单):关/2s/5s/10s 单选,当前档打勾;
/// 倒计时中点按 = 取消当前倒计时(同档重设即取消,见 setSelfTimer)。
/// 菜单颜色随应用主题。
Future<void> _pickSelfTimer(
    BuildContext chipContext, RemoteController controller) async {
  if (controller.selfTimerCountdown != null) {
    controller.setSelfTimer(controller.selfTimerSeconds);
    return;
  }
  final live = LiveDesign.of(chipContext);
  final box = chipContext.findRenderObject() as RenderBox?;
  final overlay = Navigator.of(chipContext).overlay?.context.findRenderObject()
      as RenderBox?;
  if (box == null || overlay == null) return;
  final value = await showMenu<int>(
    context: chipContext,
    color: live.surface,
    position: RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final s in const [0, 2, 5, 10])
        PopupMenuItem<int>(
          value: s,
          child: Row(
            children: [
              Text(
                  s == 0
                      ? chipContext.t('common.offShort')
                      : chipContext.t('common.seconds', {'s': '$s'}),
                  style: TextStyle(fontSize: 14, color: live.text)),
              if (s == controller.selfTimerSeconds) ...[
                const Spacer(),
                Icon(Icons.check, size: 18, color: live.accent),
              ],
            ],
          ),
        ),
    ],
  );
  if (value != null) controller.setSelfTimer(value);
}

/// 间隔拍摄参数底单(芯片 → 底部弹层):间隔(秒,1-3600 钳制在
/// [IntervalConfig])+ 张数(0 = ∞ 无限轮)两行步进 + 开始钮。
/// 启动互锁在控制器([RemoteController.startInterval]):B 门/录像/
/// SDRAM/自拍倒计时中拒绝并 notice 指路。菜单颜色随应用主题。
Future<void> _pickInterval(
    BuildContext chipContext, RemoteController controller) async {
  var intervalSec = 5;
  var shots = 10; // 0 = ∞
  await showModalBottomSheet<void>(
    context: chipContext,
    backgroundColor: LiveDesign.of(chipContext).surface,
    builder: (sheetContext) => SafeArea(
      child: StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sheetContext.t('interval.setupTitle'),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: LiveDesign.of(sheetContext).text)),
              const SizedBox(height: 10),
              _intervalStepper(
                sheetContext,
                label: sheetContext.t('interval.interval'),
                valueLabel: intervalSec >= 60
                    ? sheetContext.t('interval.minSec',
                        {'m': '${intervalSec ~/ 60}', 's': '${intervalSec % 60}'})
                    : sheetContext.t('common.seconds', {'s': '$intervalSec'}),
                onDecr: intervalSec > 1
                    ? () => setSheetState(() => intervalSec--)
                    : null,
                onIncr: intervalSec < 3600
                    ? () => setSheetState(() {
                          // 5s 内逐秒,之后粗步进(1/5/10/30/60 …)
                          intervalSec += intervalSec < 5
                              ? 1
                              : intervalSec < 10
                                  ? 5
                                  : intervalSec < 60
                                      ? 10
                                      : intervalSec < 300
                                          ? 60
                                          : 300;
                        })
                    : null,
              ),
              _intervalStepper(
                sheetContext,
                label: sheetContext.t('interval.count'),
                valueLabel: shots == 0
                    ? sheetContext.t('interval.unlimited')
                    : '$shots',
                onDecr: shots > 0
                    ? () => setSheetState(() => shots--)
                    : null,
                onIncr: shots < 9999
                    ? () => setSheetState(() {
                          shots += shots < 10 ? 5 : shots < 100 ? 10 : 100;
                        })
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                sheetContext.t('interval.hint'),
                style: TextStyle(
                    fontSize: 11, color: LiveDesign.of(sheetContext).faint),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('interval-start'),
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    controller.startInterval(
                        intervalSeconds: intervalSec,
                        shotCount: shots == 0 ? null : shots);
                  },
                  child: Text(sheetContext.t('interval.start')),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 参数步进行(label + 值 + −/+)。
Widget _intervalStepper(
  BuildContext context, {
  required String label,
  required String valueLabel,
  VoidCallback? onDecr,
  VoidCallback? onIncr,
}) {
  final live = LiveDesign.of(context);
  Widget side(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 36,
          child: Icon(icon,
              size: 20,
              color: onTap != null ? live.text : live.faint),
        ),
      );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: live.muted)),
        const Spacer(),
        side(Icons.remove_circle_outline, onDecr),
        SizedBox(
          width: 96,
          child: Text(valueLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: live.text,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        side(Icons.add_circle_outline, onIncr),
      ],
    ),
  );
}
