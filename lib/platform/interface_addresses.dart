/// 本机 IPv4 接口地址取用(dart:io NetworkInterface 薄 glue)。
///
/// 服务 /24 网段扫描(core/ptpip/subnet_scan.dart):core 不反向依赖
/// platform,扫描器经构造注入取用函数,生产装配(connection_page 的
/// ConnectionController 默认构造)传本 glue,测试传 fake。
library;

import 'dart:io';

/// 当前所有非回环 IPv4 接口地址(点分字符串)。
///
/// 吞错(权限/平台差异):取不到 = 空表,扫描自然无候选(调用方
/// 无需也无需区分失败形态)。回环/链路本地的剔除在
/// [subnetCandidates](纯函数,可测)里做。
Future<List<String>> currentIpv4InterfaceAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final itf in interfaces)
        for (final addr in itf.addresses) addr.address,
    ];
  } on Object {
    return const [];
  }
}
