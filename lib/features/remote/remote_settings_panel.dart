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
/// 同款)④辅助芯片(对焦后拍/SDRAM 直拍/AE-L/自拍/APP 接管)。[maxHeight] 限高内滚
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

  /// 音量键快门落定(Android 独有行):只写设置;原生开关沿
  /// (setEnabled 推/撤)由页面侧在接线沿收口。[volumeKeyShutterAvailable]
  /// = 平台门禁(Android 才 true;iOS 系统不放行音量键到应用、ohos 未做
  /// 原生拦截,行不出现)。
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
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(live, context.t('拍摄参数')),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final p in orderedCaptureParams(
                    videoMode: controller.cameraMode == CaptureMode.video))
                  captureParamTileOf(
                      context, controller, activeParam, onEditParam, p),
              ],
            ),
            _sectionHeader(live, context.t('对焦')),
            _focusControls(context),
            _sectionHeader(live, context.t('监看')),
            _monitorToggles(context),
            _liveViewQualityRows(context),
            _sectionHeader(live, context.t('辅助')),
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

  Widget _sectionHeader(LivePalette live, String label) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: live.faint)),
      );

  /// 对焦控制组(2026-10-12 自对焦浮层迁入):MF 步进(0x9204 相对量,
  /// 近/远各一步)+ 拉焦轮开关(取景画面右缘竖条,开 = 金;重开清失败
  /// 预算 resetFocusDial,从可用态起步)。机身对焦模式为 MF 时全部灰化
  /// (机内马达脱开,远程对焦失效 —— 只有镜头对焦环能动焦)+ 常驻提示
  /// 行(盲按无响应的困惑根源)。
  Widget _focusControls(BuildContext context) {
    final live = LiveDesign.of(context);
    final usable = controller.linkUp &&
        controller.liveViewActive &&
        !controller.focusModeIsMf;
    Widget step(IconData icon, bool towardNear, String label, String tip) {
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: usable
              ? () => controller.mfDriveStep(towardNear: towardNear)
              : null,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  height: 34,
                  child: Material(
                    color: live.glass,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: live.hairline),
                    ),
                    child: InkWell(
                      onTap: usable
                          ? () => controller.mfDriveStep(towardNear: towardNear)
                          : null,
                      customBorder: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(icon,
                          size: 18, color: usable ? live.text : live.faint),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 10, color: live.faint)),
              ],
            ),
          ),
        ),
      );
    }

    final dialOn = toggles.focusDial;
    // 主体追踪(0x9424/0x9425):门控 = 取景在 + 非 MF + AF 区域「自动」
    // (0x8011;芯片读控制器实时值);追踪进行中保持可点(停止优先于门控)。
    final trackUsable = usable && controller.afAreaCanTrack;
    Widget trackChip = _smallChip(
      live: live,
      label: context.t('主体追踪'),
      selected: controller.tracking,
      onTap: controller.tracking
          ? controller.endTracking
          : (trackUsable ? controller.startTracking : null),
      tooltip: context.t('启动后相机持续追焦所选主体(点取景画面选目标),再点停止'),
    );
    Widget dialToggle = InkWell(
      onTap: () {
        if (!dialOn) controller.resetFocusDial();
        onTogglesChanged(toggles.copyWith(focusDial: !dialOn));
      },
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 34,
              child: Material(
                color: dialOn ? live.accentDim : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: dialOn
                        ? live.accent.withValues(alpha: 0.5)
                        : live.hairline,
                  ),
                ),
                child: Icon(Icons.vertical_align_center,
                    size: 18, color: dialOn ? live.accent : live.muted),
              ),
            ),
            const SizedBox(height: 2),
            Text(context.t('拉焦轮'),
                style: TextStyle(
                    fontSize: 10, color: dialOn ? live.accent : live.faint)),
          ],
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 2,
          runSpacing: 4,
          children: [
            step(Icons.remove, true, context.t('MF 近'), context.t('MF 向近(步进)')),
            step(Icons.add, false, context.t('MF 远'), context.t('MF 向远(步进)')),
            dialToggle,
            trackChip,
          ],
        ),
        if (controller.focusModeIsMf) ...[
          const SizedBox(height: 6),
          Text(context.t('机身对焦模式为 MF,远程对焦已停用'),
              style: TextStyle(fontSize: 10, color: live.muted)),
        ] else if (usable && !controller.afAreaCanTrack) ...[
          const SizedBox(height: 6),
          Text(context.t('主体追踪:AF 区域切到「自动」后可用'),
              style: TextStyle(fontSize: 10, color: live.muted)),
        ],
      ],
    );
  }

  /// 监看开关组(原辅助浮层迁移,拉焦轮除外 —— 在上方对焦段):取景
  /// 打头(十二轮总开关,当前态跟 liveViewActive,录制中禁点 —— 视频
  /// 模式停录门依赖取景在跑);网格等六项走 [toggles]。斑马纹/直方图/
  /// 伪色/峰值四项共享一份帧分析 —— 开关落定后由页面同步
  /// RemoteController.analyzer 启停(见 RemotePage._syncAnalyzerEnabled)。
  Widget _monitorToggles(BuildContext context) {
    final live = LiveDesign.of(context);
    Widget toggle(
        IconData icon, String label, bool current, void Function(bool) set,
        {bool enabled = true}) {
      // 命中区 ≥44×44(视觉盒 40×34 不变,标签纳入点击):InkWell 包住
      // 整列再垫透明 padding;外层不画水波/高亮 —— 视觉零变化。
      return InkWell(
        onTap: enabled ? () => set(!current) : null,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 34,
                child: Material(
                  color: current ? live.accentDim : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: current
                          ? live.accent.withValues(alpha: 0.5)
                          : live.hairline,
                    ),
                  ),
                  child: InkWell(
                    onTap: enabled ? () => set(!current) : null,
                    customBorder: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon,
                        size: 18,
                        color: !enabled
                            ? live.faint
                            : current
                                ? live.accent
                                : live.muted),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      color: !enabled
                          ? live.faint
                          : current
                              ? live.accent
                              : live.faint)),
            ],
          ),
        ),
      );
    }

    final chips = Wrap(
      spacing: 2,
      runSpacing: 4,
      children: [
        // 取景总开关(十二轮「取景器关闭的开关」):当前态跟
        // liveViewActive(起景失败/引擎态即时可见,不跟持久位);录制中
        // 禁点 —— 视频模式停录门依赖取景在跑。
        toggle(Icons.videocam_outlined, context.t('取景'),
            controller.liveViewActive, onLiveViewToggle,
            enabled: !controller.recording),
        toggle(Icons.grid_on, context.t('网格'), toggles.grid,
            (v) => onTogglesChanged(toggles.copyWith(grid: v))),
        toggle(Icons.warning_amber, context.t('斑马纹'), toggles.zebra,
            (v) => onTogglesChanged(toggles.copyWith(zebra: v))),
        toggle(Icons.bar_chart, context.t('直方图'), toggles.histogram,
            (v) => onTogglesChanged(toggles.copyWith(histogram: v))),
        toggle(Icons.linear_scale, context.t('水平仪'), toggles.level,
            (v) => onTogglesChanged(toggles.copyWith(level: v))),
        toggle(Icons.palette_outlined, context.t('伪色'), toggles.falseColor,
            (v) => onTogglesChanged(toggles.copyWith(falseColor: v))),
        toggle(Icons.blur_on, context.t('峰值'), toggles.peaking,
            (v) => onTogglesChanged(toggles.copyWith(peaking: v))),
        // 波形示波器(帧分析路:开关落定由页面同步分析器启停)。
        toggle(Icons.stacked_line_chart, context.t('波形'), toggles.waveform,
            (v) => onTogglesChanged(toggles.copyWith(waveform: v))),
        // 构图框三件(纯显示层,不占分析器):遮幅循环芯片 + 安全框 +
        // 中心标。
        _smallChip(
          live: live,
          // framingAspect.label 是画幅比数字串(「2.39」等),无需翻译。
          label: toggles.framingAspect == FramingAspect.off
              ? context.t('遮幅')
              : context.t('遮幅 {v}', {'v': toggles.framingAspect.label}),
          selected: toggles.framingAspect != FramingAspect.off,
          onTap: () => onTogglesChanged(
              toggles.copyWith(framingAspect: toggles.framingAspect.next)),
          tooltip: context.t('构图遮幅:2.39/2.35/1.85 循环;画幅外压暗(变宽还原已计入)'),
        ),
        toggle(Icons.crop_free, context.t('安全框'), toggles.framingSafeArea,
            (v) => onTogglesChanged(toggles.copyWith(framingSafeArea: v))),
        toggle(
            Icons.center_focus_weak,
            context.t('中心标'),
            toggles.framingCenterMark,
            (v) => onTogglesChanged(toggles.copyWith(framingCenterMark: v))),
        // 内屏强关(0x9422,B 组线上未验):乐观态会话级,tooltip 标
        // 实验性(副作用未知,断流由看门狗兜底)。
        Tooltip(
          message: context.t('实验性:强制关闭机背内屏(重连/重开后状态未知)'),
          child: toggle(Icons.mobile_off, context.t('内屏'),
              controller.monitorOff, (_) => controller.toggleMonitorOff(),
              enabled: controller.linkUp),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chips,
        const SizedBox(height: 4),
        _monitorLutRow(context),
        // 峰值选项行:峰值开着才出现(关了藏行,少占面板高)。
        if (toggles.peaking) ...[
          const SizedBox(height: 4),
          _peakingOptionRows(context),
        ],
      ],
    );
  }

  /// 监看 LUT 芯片行(内置风格表,纯显示层调色;选中即走高质量渲染
  /// 管线 —— 查表只在 shader 路径,设备不支持时无 LUT 画面照常)。
  Widget _monitorLutRow(BuildContext context) {
    final live = LiveDesign.of(context);
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: context.t('监看套色(不写帧数据):选中即自动走高质量渲染管线,shader 不可用时无 LUT'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(context.t('监看 LUT'),
                style: TextStyle(fontSize: 11, color: live.faint)),
          ),
        ),
        _smallChip(
          live: live,
          label: context.t('关'),
          selected: toggles.lutIndex < 0,
          onTap: () => onTogglesChanged(toggles.copyWith(lutIndex: -1)),
        ),
        for (var i = 0; i < builtinLuts.length; i++)
          _smallChip(
            live: live,
            // LUT 标题(edit/lut_presets 的 builtinLuts 产出)原文即
            // t() 键,显示点包 t()。
            label: context.t(builtinLuts[i].title),
            selected: toggles.lutIndex == i,
            onTap: () => onTogglesChanged(toggles.copyWith(lutIndex: i)),
          ),
      ],
    );
  }

  /// 峰值选项行(2026-10-14 灵敏度/颜色可配):灵敏度三档(低/中/高 =
  /// 梯度阈值 24/40/64,调优档非协议常量,映射在 monitor_toggles 的
  /// monitorPeakingThresholdOf)+ 高亮色三档(金/白/红,取色在
  /// live_view_overlays 的 peakingColorOf);走 [onTogglesChanged] 持久化。
  Widget _peakingOptionRows(BuildContext context) {
    final live = LiveDesign.of(context);
    Widget row(String label, List<(String, int)> options, int current,
        void Function(int) pick) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(label,
                  style: TextStyle(fontSize: 11, color: live.faint)),
            ),
            for (final option in options)
              _smallChip(
                live: live,
                // 选项文案(本文件调用点的字面量表)经 t() 查目录,
                // 表外值(QVGA 等拉丁串)未命中原样回落。
                label: context.t(option.$1),
                selected: current == option.$2,
                onTap: () => pick(option.$2),
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
            context.t('峰值灵敏度'),
            const [('低', 0), ('中', 1), ('高', 2)],
            toggles.peakingLevel,
            (v) => onTogglesChanged(toggles.copyWith(peakingLevel: v))),
        row(
            context.t('峰值颜色'),
            const [('金', 0), ('白', 1), ('红', 2)],
            toggles.peakingColor,
            (v) => onTogglesChanged(toggles.copyWith(peakingColor: v))),
      ],
    );
  }

  /// 取景画质行(2026-10-12 官方 §6.5.11.4-5):尺寸档决定 0x9428 帧
  /// 分辨率(QVGA 省流量 / XGA 提清晰度),压缩档决定 JPEG 质量;选值
  /// 即写相机(链路在)+ 持久化,「跟随」= 不写机身菜单既有值。
  Widget _liveViewQualityRows(BuildContext context) {
    final live = LiveDesign.of(context);
    Widget row(String label, List<(String, int?)> options, int? current,
        void Function(int?) pick) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(label,
                  style: TextStyle(fontSize: 11, color: live.faint)),
            ),
            for (final option in options)
              _smallChip(
                live: live,
                // 选项文案经 t() 查目录,QVGA/VGA/XGA 等拉丁串未命中
                // 原样回落。
                label: context.t(option.$1),
                selected: current == option.$2,
                onTap: () => pick(option.$2),
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
            context.t('取景尺寸'),
            const [
              ('跟随', null),
              ('QVGA', 1),
              ('VGA', 2),
              ('XGA', 3),
            ],
            liveViewImageSize,
            (v) => onLiveViewQualityChanged(v, liveViewImageCompression)),
        row(
            context.t('取景画质'),
            const [
              ('跟随', null),
              ('Basic 尺寸', 0),
              ('Basic 质量', 1),
              ('Normal 尺寸', 2),
              ('Normal 质量', 3),
              ('Fine 尺寸', 4),
              ('Fine 质量', 5),
            ],
            liveViewImageCompression,
            (v) => onLiveViewQualityChanged(liveViewImageSize, v)),
      ],
    );
  }

  /// 辅助芯片组(原辅助浮层迁移):对焦后拍 / 自拍 / APP 接管。
  Widget _assistChips(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _smallChip(
          live: LiveDesign.of(context),
          label: context.t('对焦后拍'),
          selected: controller.focusBeforeCapture,
          onTap: () =>
              controller.focusBeforeCapture = !controller.focusBeforeCapture,
          tooltip: context.t('释放快门前先自动对焦(半按-全按;候选参数,待真机核对)'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: context.t('SDRAM 直拍'),
          selected: controller.sdramCapture,
          onTap: () => onSdramCaptureChanged(!controller.sdramCapture),
          tooltip: context.t('AF+SDRAM 一体拍(0x90CB):对象不入卡,回传 APP 存图库'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: 'AE-L',
          selected: controller.aeLocked,
          onTap: !controller.linkUp ? null : controller.toggleAELock,
          tooltip: context.t('AE/AWB 锁定(0x9426):曝光随锁定时刻固定,再点解除'),
        ),
        _smallChip(
          live: LiveDesign.of(context),
          label: 'GPS',
          selected: bleGpsInject,
          onTap: !bleReady ? null : () => onBleGpsInjectChanged(!bleGpsInject),
          tooltip: bleReady
              ? context.t('BLE 定位注入(0x2007):拍进卡的照片原生带 EXIF 坐标')
              : context.t('未配对:设置页「BLE 配对 / GPS 注入」先配对相机'),
        ),
        // Android 独有:异端不出行(iOS 不放行音量键、ohos 未做拦截)。
        if (volumeKeyShutterAvailable)
          _smallChip(
            live: LiveDesign.of(context),
            label: context.t('音量键快门'),
            selected: volumeKeyShutter,
            onTap: () => onVolumeKeyShutterChanged(!volumeKeyShutter),
            tooltip: context.t(
              '音量上/下键兼作快门(拍摄页存续期生效);'
              '仅 Android —— iOS 系统不放行音量键给应用,ohos 未做拦截',
            ),
          ),
        Builder(
          // Builder 让 showMenu 锚到自拍芯片本身(而非整条浮层)。
          builder: (chipContext) => _smallChip(
            live: LiveDesign.of(chipContext),
            label: controller.selfTimerSeconds == 0
                ? context.t('自拍')
                : context.t('自拍 {s}s', {'s': '${controller.selfTimerSeconds}'}),
            selected: controller.selfTimerSeconds > 0,
            onTap: () => _pickSelfTimer(chipContext, controller),
            tooltip: context.t('自拍定时:关/2s/5s/10s 点选;倒计时中再点取消'),
          ),
        ),
        _takeoverChip(context,
            controller: controller, onTakeoverRequest: onTakeoverRequest),
      ],
    );
  }
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
    label: active ? context.t('APP 接管中') : context.t('APP 接管'),
    selected: active,
    onTap: !controller.linkUp
        ? null
        : (active
            ? controller.releaseTakeover
            : () => onTakeoverRequest(context)),
    tooltip: context.t('拨盘级参数(快门/模式/ISO/光圈)需先接管才能遥控调整'),
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
                      ? chipContext.t('关')
                      : chipContext.t('{s} 秒', {'s': '$s'}),
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
