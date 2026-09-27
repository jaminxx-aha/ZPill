/// 遥控拍摄页(TODO.md §六 P3,骨架)。
///
/// PTP 操作:快门释放(InitiateCapture 0x100E)、半按/触点对焦、
/// 曝光查询与设置(Get/SetDevicePropValue 0x1015/0x1016)。
library;

import 'package:flutter/material.dart';

class RemotePage extends StatelessWidget {
  const RemotePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('遥控拍摄')),
      body: const Center(
        child: Text(
          'P3:快门释放 / 触点对焦 / 曝光设置\n(InitiateCapture 0x100E,Get/SetDevicePropValue 0x1015/0x1016)',
          textAlign: TextAlign.center,
        ),
      ),
      // TODO(P3): 取景流(依赖相机型号能力,需真机调研)、
      // 快门按钮(半按=对焦,全按=释放)、曝光参数控件。
    );
  }
}
