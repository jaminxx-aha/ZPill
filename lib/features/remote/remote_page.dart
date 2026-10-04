/// 遥控拍摄页:Live View 监看 + 快门释放 + 曝光只读。
///
/// PTP 操作:0x9201/0x9203/0x9202 取景三步(候选码,待真机核对)、
/// InitiateCapture 0x100E 快门、GetDevicePropValue 0x1015 曝光三要素。
/// SetDevicePropValue(0x1016)已编码但被 PtpSession.kSetPropEnabled 门禁
/// (可写域真机核对后翻开,届时补曝光调节控件)。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/remote/live_view_engine.dart';
import 'remote_controller.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, this.controller});

  final RemoteController? controller;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final RemoteController controller;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppServices.instance.remoteController;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离页即停取景:引擎归 AppServices 单例持有,不停会在后台持续打链路。
    if (controller.liveViewActive) {
      unawaited(controller.toggleLiveView());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台停取景:相机侧 Live View 是高功耗状态,且 iOS/ohos 后台
    // 网络不保活(与下载页同款约束)。
    if (state == AppLifecycleState.paused && controller.liveViewActive) {
      unawaited(controller.toggleLiveView());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('遥控拍摄')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            controller.engine.frame,
            controller.engine.status,
          ]),
          builder: (context, _) {
            final exposure = controller.exposure;
            return Column(
              children: [
                Expanded(child: _frameArea(context)),
                if (!controller.linkUp)
                  _banner(context, '未连接相机 —— 请先在连接页建立连接',
                      Colors.orange)
                else if (controller.error != null)
                  _banner(context, controller.error!, Colors.red),
                if (controller.notice != null)
                  _banner(context, controller.notice!, Colors.green),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _exposureChip('光圈', exposure?.fNumber == null
                          ? '--'
                          : 'f/${(exposure!.fNumber! / 10).toStringAsFixed(1)}'),
                      _exposureChip('快门', _formatShutter(exposure?.shutterUs)),
                      _exposureChip('ISO',
                          exposure?.iso == null ? '--' : 'ISO ${exposure!.iso}'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _liveViewToggle(context),
                      _shutterButton(context),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _frameArea(BuildContext context) {
    final Uint8List? frame = controller.engine.frame.value;
    final status = controller.engine.status;
    return Container(
      color: Colors.black,
      width: double.infinity,
      child: frame != null
          ? Image.memory(frame, fit: BoxFit.contain,
              gaplessPlayback: true) // 换帧不闪黑
          : Center(
              child: Text(
                status.value == LiveViewStatus.running
                    ? '取景中…(等待首帧)'
                    : status.value == LiveViewStatus.failed
                        ? '取景失败(${controller.engine.lastError ?? "未知错误"})'
                        : '取景已关闭\n开启「取景」查看实时画面',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
    );
  }

  Widget _banner(BuildContext context, String text, Color color) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: color)),
    );
  }

  Widget _exposureChip(String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text(value, style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }

  Widget _liveViewToggle(BuildContext context) {
    final active = controller.liveViewActive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'liveview',
          onPressed: () => controller.toggleLiveView(),
          child: Icon(active ? Icons.videocam_off : Icons.videocam),
        ),
        const SizedBox(height: 4),
        Text(active ? '取景中' : '取景'),
      ],
    );
  }

  Widget _shutterButton(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: FloatingActionButton(
            heroTag: 'shutter',
            backgroundColor: controller.linkUp ? null : Colors.grey,
            onPressed:
                controller.capturing || !controller.linkUp
                    ? null
                    : () => controller.capture(),
            child: controller.capturing
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Icon(Icons.photo_camera, size: 36),
          ),
        ),
        const SizedBox(height: 4),
        const Text('快门'),
      ],
    );
  }

  String _formatShutter(int? us) {
    if (us == null || us <= 0) return '--';
    if (us >= 1000000) {
      final s = us / 1000000;
      return '${s == s.roundToDouble() ? s.toInt() : s.toStringAsFixed(1)}s';
    }
    return '1/${(1000000 / us).round()}s';
  }
}
