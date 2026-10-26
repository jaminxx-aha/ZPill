/// ohos bulk IN submit 流水线探针(诊断):usbSubmitTransfer URB 预提交
/// vs sync bulkTransfer 定值 128KB 墙。
///
/// 背景(2026-10-25):ohos 有线下载 ~6MB/s —— @ohos.usbManager 的 sync
/// `bulkTransfer` 每次调用固定开销 ~9ms 不随尺寸摊薄,真机阶梯 256KB
/// 挂死(Promise 永不返回)/1MB 恒 rc=-1,AIMD 只能钉 128KB(≈10MB/s
/// 原始上限,UI 口径 ~6MB/s)。`usbSubmitTransfer`(@since 18)是 URB
/// 异步提交 + 完成回调 + 每笔独立超时:相机出数与主机收数重叠,sync 路
/// 的「提交→等完成」串行等待被摊掉。
///
/// 第一轮(2026-10-26 真机)定案:d=1 单笔已赢 sync 路(64KB=11.0、
/// 128KB=13.1MB/s,固定开销 ~2.2ms vs sync ~6.7ms);**深度 ≥2 = URB
/// 瞬间「完成」但恒 0 字节**(空完成,无错无超时,数据相被静默丢)
/// —— 并发 URB 在本机 daemon 层不出数据,流水线死路,单笔大缓冲是
/// 唯一杠杆。第二轮改纯尺寸爬坡(d=1:64K→8M,找 sync 路 256KB 挂死
/// 在 submit 路的同位病);每档之间 native drainIn 排空(失败档残留
/// 旧数据相会毒下一档,d=2/4 连挂即此因);d=2 留一档复验空完成。
///
/// 路线:连接落定沿自动跑(受 OHOS_SUBMIT_PROBE 总闸,装配在
/// app_services);每档 = native setSubmitPipe(depth, buf) 后经生产下载
/// 路(整档 GetObject)拉全卡最大静照一张,对账 Dart 计时 + native
/// URB 记账。输出走 AppLog(transfer 域)随设置页导出;hilog 直写
/// (domain 0xFF00, TAG UsbHostPlugin)供真机自驱对账;探针用完不删
/// (诊断惯例,见 ic_download_probe.dart)。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/browser/object_entry.dart';
import '../core/log/app_log.dart';
import '../core/ptp/ptp_session.dart';
import '../core/ptpip/object_format.dart';
import '../core/transfer/object_downloader.dart';
import 'ic_download_probe.dart';

/// 总闸(--dart-define=OHOS_SUBMIT_PROBE=true)。
const bool kOhosSubmitProbe = bool.fromEnvironment('OHOS_SUBMIT_PROBE');

final class OhosSubmitPipeProbe {
  OhosSubmitPipeProbe._();

  static const MethodChannel _usb = MethodChannel('nikonpill/usb');

  /// (深度 × 缓冲 × 重复)阶梯 v5:sync 基线锚定;512K 单发(衔接 v4
  /// 口径,带常规间隙);512K ×6 零间隙连下(生产节拍模拟 —— v4 定案
  /// 的「档间 ~500ms 间隙 → 下笔事务 15s 沉默」若真由间隙触发,连下
  /// 应无死窗且吞吐站住 ~20MB/s,此档即生产可行性判据)。
  static const List<List<int>> _configs = <List<int>>[
    <int>[0, 0, 1],
    <int>[1, 512 * 1024, 1],
    <int>[1, 512 * 1024, 6],
  ];

  /// 连接落定沿入口(受 [kOhosSubmitProbe] 总闸,装配在 app_services)。
  ///
  /// 单飞闸:session_lifecycle 的 onConnectedSettled 在**每个 connected
  /// 沿**都发(重连也算,无 once 闸)—— 链路一抖就叠出第二个 run,两个
  /// run 互踩(setSubmitPipe 重置对方配置/cancel 掐对方在途 URB/流错位
  /// 连环失败,v2 真机已实证)。重入直接跳过。
  static bool _running = false;

  static Future<void> run({
    required PtpSession session,
    required ObjectDownloader downloader,
    required Future<String> Function() tempDir,
  }) async {
    if (_running) {
      AppLog.w(AppLog.transfer, 'submitPipe 探针: 已在跑,跳过重入');
      return;
    }
    _running = true;
    try {
      final entry =
          await IcDownloadProbe.pickLargest(session, ObjectKind.image);
      if (entry == null) {
        AppLog.i(AppLog.transfer, 'submitPipe 探针: 卡上无静照对象');
        return;
      }
      AppLog.i(AppLog.transfer,
          'submitPipe 选靶: ${entry.name} ${(entry.sizeInBytes / 1048576).toStringAsFixed(1)}MB');
      await _plog('选靶: ${entry.name} ${(entry.sizeInBytes / 1048576).toStringAsFixed(1)}MB'
          ' handle=0x${entry.handle.toRadixString(16)}');
      var badStreak = 0;
      for (final c in _configs) {
        final ok =
            await _runOne(c[0], c[1], c.length > 2 ? c[2] : 1, entry, downloader, tempDir);
        badStreak = ok ? 0 : badStreak + 1;
        if (badStreak >= 3) {
          AppLog.w(AppLog.transfer, 'submitPipe: 连续 3 档失败,链路疑死,中止');
          await _plog('连续 3 档失败,链路疑死,中止');
          break;
        }
      }
      // 收态:关闸回 sync 路(重连后 native 也自会重置)。
      await _setPipe(false, 1, 64 * 1024);
    } on Exception catch (e) {
      AppLog.e(AppLog.transfer, 'submitPipe 探针失败: $e');
      try {
        await _setPipe(false, 1, 64 * 1024);
      } on Exception {
        // 收态失败不掩盖探针结果
      }
    } finally {
      _running = false;
    }
  }

  /// 单档:开闸 → 下载选靶 → 对账(下载产物是探针素材,拉完即删);
  /// 收沿无条件 drainIn 排空 —— 成功档数据相已尽,排水是 ~300ms 空转;
  /// 失败档残留旧数据相字节,不清会毒下一档(第一轮 d=2/4 连挂即此因)。
  /// depth=0 = sync 基线(pipe 关闸,走生产 sync bulkTransfer 路)。
  /// repeats>1 = 零间隙连下(v5 生产节拍判据):开闸一次,循环下载
  /// 之间不插任何通道调用(stats/drain 全部收尾一次),逐遍 [dart] 记时。
  static Future<bool> _runOne(int depth, int bufBytes, int repeats,
      ObjectEntry entry, ObjectDownloader downloader,
      Future<String> Function() tempDir) async {
    final tag = depth == 0
        ? 'submitPipe SYNC基线'
        : 'submitPipe d=$depth buf=${bufBytes ~/ 1024}KB';
    try {
      if (depth == 0) {
        await _setPipe(false, 1, 64 * 1024);
      } else {
        await _setPipe(true, depth, bufBytes);
      }
      await _plog('$tag 开跑${repeats > 1 ? ' ×$repeats 零间隙' : ''}');
      for (var i = 1; i <= repeats; i++) {
        final sub = repeats > 1 ? '[$i/$repeats]' : '';
        final dl =
            await downloader.download(entry, targetDir: await tempDir());
        await _plog('$tag$sub 成功: ${dl.bytes}B '
            '${dl.elapsed.inMilliseconds}ms = '
            '${dl.megabytesPerSecond.toStringAsFixed(1)}MB/s');
        try {
          await File(dl.path).delete();
        } on Exception {
          // 清扫失败不掩盖探针结果
        }
      }
      final stats = await _stats();
      await _plog('$tag 汇总 native[$stats]');
      return true;
    } on Exception catch (e) {
      AppLog.w(AppLog.transfer, '$tag 失败: $e');
      await _plog('$tag 失败: $e');
      return false;
    } finally {
      try {
        await _usb.invokeMethod<int>('drainIn');
      } on Exception {
        // 排空失败不掩盖本档结果
      }
    }
  }

  /// Dart→native hilog 桥:探针关键行同步镜像进 hilog(真机自驱对账;
  /// AppLog 在 Release 不落 hilog,沙盒 hdc 又进不去 —— 沙盒只读实证)。
  static Future<void> _plog(String line) async {
    try {
      await _usb.invokeMethod<void>('probeLog', {'line': line});
    } on Exception {
      // 镜像失败不掩盖主账
    }
  }

  static Future<void> _setPipe(bool enabled, int depth, int bufBytes) async {
    await _usb.invokeMethod<void>('setSubmitPipe', {
      'enabled': enabled,
      'depth': depth,
      'bufBytes': bufBytes,
    });
  }

  static Future<String> _stats() async {
    final r = await _usb.invokeMethod<Map<dynamic, dynamic>>('submitPipeStats');
    if (r == null) return '无账';
    return 'urbs=${r['urbs']} bytes=${r['bytes']} ms=${r['ms']} zlb=${r['zlb']} '
        'short=${r['shortReads']} timeout=${r['timeouts']} err=${r['errors']} '
        'maxActual=${r['maxActual']}';
  }
}
