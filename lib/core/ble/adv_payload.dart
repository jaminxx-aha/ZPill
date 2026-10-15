/// Nikon BLE 广播厂商数据(manufacturer specific data,公司 ID 0x0399)
/// 的纯 Dart 解析 —— 重连匹配(lib/platform/ble_scanner.dart 的
/// scanForDeviceId,native 过滤)之外,把同一份字节上行给 UI 做结构化
/// 展示与「在等别的手机」冲突判定。
///
/// 布局(与两端 native 过滤器逐字节互证,2026-10-15):
/// `[u16 LE 公司 ID = 0x0399(字节 99 03)][u32 LE deviceId]`,其后可能
/// 有尾随字节,忽略。iOS(ios/Runner/BlePlugin.swift didDiscover 的
/// scanFilterDeviceId 分支)与 Android(android/.../BlePlugin.kt
/// onScanResult 的 scanFilterDeviceId 分支)同语义:长度 ≥ 6、公司 ID
/// 比对、只看字节 [2..5];Android 的 map 值不含两字节 ID 前缀,native
/// 已补齐 [0x99,0x03] 再上行(见 BleDevice.mfgData 注),故本层看到的
/// mfg 恒带前缀。deviceId 按**无符号** u32 解读 —— 与配对引擎
/// _newDeviceId 的全 32 位取值域一致(Android native 以 Int32 有符号
/// 汇装,同位型比对,数值语义等价)。
///
/// 语义(HarmoNiLink 口径转述,只借思路不搬码):0x0399 只在**已配对**
/// 相机的广播里出现(配对菜单态不带);deviceId 标识「配对关系」而非
/// 机身 —— 相机广播的是它当前配对目标的 ID,在等别的手机(如
/// SnapBridge)的相机广播的就是那个手机的 ID;重新配对即更换。
library;

import 'dart:typed_data';

/// Nikon 公司 ID:BLE 厂商数据首两字节小端(99 03)。
const int kNikonBleCompanyId = 0x0399;

/// 解析广播厂商数据里的「期望控制器 deviceId」。
///
/// 返回 null = 不可解析:空数据 / 短包(<6B)/ 公司 ID 不符(含配对
/// 菜单态相机 —— 本就不带 0x0399)。可解析时返回无符号 u32。
int? expectedControllerDeviceId(Uint8List? mfg) {
  if (mfg == null || mfg.length < 6) return null;
  if (mfg[0] != 0x99 || mfg[1] != 0x03) return null;
  return mfg[2] | (mfg[3] << 8) | (mfg[4] << 16) | (mfg[5] << 24);
}

/// 相机是否「在等别的手机」:广播可解出期望 deviceId,且与我方注册
/// 身份的 deviceId 都在且不同(同 ID = 相机在等我们自己)。
/// 无注册身份(ownDeviceId null,首次配对无从比较)恒 false。
bool cameraWaitsForOtherController(Uint8List? mfg, int? ownDeviceId) {
  final expected = expectedControllerDeviceId(mfg);
  return expected != null && ownDeviceId != null && expected != ownDeviceId;
}
