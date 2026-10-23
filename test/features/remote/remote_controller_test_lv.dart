part of 'remote_controller_test.dart';

void _lvGroups() {
    group('拍摄页可见性(取景生命周期跟连接走)', () {
      test('setViewerVisible(false):帧轮询与 AE 轮询挂起,不发 0x9202;'
          '回台恢复', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // 串链自动起景(0x9201 + 首帧)
        await pumpEventQueue();
        expect(controller.liveViewActive, isTrue,
            reason: 'connected 沿串链起景(2026-10-11 移入)');
        expect(transport.count(NikonOperationCode.getLiveViewImageEx), 1);

        // 离台:放行挂着的 delay(AE 间隔 + 引擎间隔 + 若干挂起 tick),
        // 不得再发任何请求(脚本无应答可耗,有请求即 StateError 炸出)。
        controller.setViewerVisible(false);
        final reqsAtHide = transport.requests.length;
        for (var i = 0; i < 4; i++) {
          // release 后轮询协程异步苏醒:逐把放行逐轮冲刷(AE 醒即退出,
          // 引擎醒见挂起标志 → 再挂 tick;醒多少轮都不取帧)。
          delay.release();
          await pumpEventQueue();
        }
        expect(transport.requests.length, reqsAtHide, reason: '不可见零流量');
        expect(controller.liveViewActive, isTrue,
            reason: '相机侧取景保持(不发 0x9202)');
        expect(transport.count(NikonOperationCode.endLiveView), 0);

        // 回台:引擎恢复取帧,AE 轮询重启。AE 一轮 = fNumber PropDesc +
        // 快门 0xD100 裸读 + ISO PropDesc + ISO 0xD0B5 裸读(四请求)。
        transport.ok(data: _fakeFrame()); // 回台首帧
        transport.ok(data: _propDescDataset( // AE:fNumber PropDesc
            PtpDevicePropCode.fNumber, PtpDataType.uint16, 280,
            enums: [280, 320, 400]));
        transport.ok(data: _u32Bytes(1 << 16 | 100)); // AE:0xD100 快门
        transport.ok(data: _propDescDataset( // AE:ISO PropDesc
            PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 200,
            enums: [100, 200, 400, 800]));
        transport.ok(data: _u32Bytes(200)); // AE:0xD0B5 有效 ISO
        controller.setViewerVisible(true);
        delay.release(); // 引擎挂起 tick 醒 → 取帧
        await pumpEventQueue();
        delay.release(); // AE 间隔醒 → 三连读
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.getLiveViewImageEx), 2,
            reason: '回台恢复帧轮询');
        expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
            reason: 'AE 轮询照常刷读数');
      });

      test('connected 沿串链起景:页面不可见也 0x9201 照发、帧轮询挂起'
          '(相机侧进取景)', () async {
        controller.setViewerVisible(false); // 拍摄页不在前台
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.liveViewActive, isTrue,
            reason: '连接即取景:0x9201 不等页面可见');
        expect(transport.count(NikonOperationCode.startLiveView), 1);
        expect(transport.count(NikonOperationCode.endLiveView), 0,
            reason: '不可见只挂起轮询,不发 0x9202');

        // 不可见:放行引擎 delay 不得再取帧(醒一轮挂一轮)。
        final frames = transport.count(NikonOperationCode.getLiveViewImageEx);
        delay.release();
        await pumpEventQueue();
        delay.release();
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.getLiveViewImageEx), frames,
            reason: '帧轮询挂起,零流量');

        // 幂等:已运行再调不重发 0x9201。
        await controller.autoLiveViewOnConnect();
        expect(transport.count(NikonOperationCode.startLiveView), 1);
      });

      test('autoLiveViewOnConnect 单飞:同拍双调用共享一次 start'
          '(连接沿串链与进页沿同到的防线)', () async {
        transport
          ..ok() // 0x9201(两次调用共享这一次)
          ..ok(data: _fakeFrame()); // 首帧
        final a = controller.autoLiveViewOnConnect();
        // 首个仍在途(running 要等 0x9201 应答才置,并发 start() 会双发):
        // 单飞共享 Future,第二个调用不再过 start 门。
        final b = controller.autoLiveViewOnConnect();
        await Future.wait([a, b]);
        await pumpEventQueue();
        expect(controller.liveViewActive, isTrue);
        expect(transport.count(NikonOperationCode.startLiveView), 1);
        expect(transport.count(NikonOperationCode.getLiveViewImageEx), 1,
            reason: '轮询循环仅一条');
      });
    });
    group('取景画质档(2026-10-12 官方 §6.5.11.4-5)', () {
      test('连接沿:设过档 → 模式读后、起景前写 0xD1AC/0xD1BC(u8 显式)',
          () async {
        controller.setLiveViewQuality(imageSize: 1, compression: 5);
        _scriptParams(transport);
        _emitConnected(transport, conn);
        // 两笔画质写应答插到链首 [0xD1A6 之后、0x9201 之前]
        final d1a6 = transport.script.removeFirst();
        final start = transport.script.removeFirst();
        final frame = transport.script.removeFirst();
        transport.script
          ..addFirst(frame)
          ..addFirst(const PtpResult(responseCode: PtpResponseCode.ok)) // 0xD1BC
          ..addFirst(const PtpResult(responseCode: PtpResponseCode.ok)) // 0xD1AC
          ..addFirst(start)
          ..addFirst(d1a6);
        await pumpEventQueue();
        final ops = transport.requests.map((r) => r.opcode).toList();
        // 序 = [0xD1A6 读, 0x9201?, ...] 实际 = 模式读 → 两笔画质写 → 起景
        final writeIdx = ops.indexOf(PtpOperationCode.setDevicePropValue);
        final startIdx = ops.indexOf(NikonOperationCode.startLiveView);
        expect(writeIdx, inInclusiveRange(1, 2), reason: '画质写在模式读之后');
        expect(startIdx, 3, reason: '起景在画质写之后(首帧即目标分辨率)');
        final writes = transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
            .toList();
        expect(writes[0].params, [PtpDevicePropCode.liveViewImageSize]);
        expect(writes[0].dataOut, [1]);
        expect(writes[1].params, [PtpDevicePropCode.liveViewImageCompression]);
        expect(writes[1].dataOut, [5]);
        expect(controller.liveViewImageSize, 1);
        expect(controller.liveViewImageCompression, 5);
      });

      test('未设档(null = 跟随相机):连接沿零画质流量,序不变形', () async {
        expect(controller.liveViewImageSize, isNull);
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        final ops = transport.requests.map((r) => r.opcode).toList();
        expect(ops.take(2), [
          PtpOperationCode.getDevicePropValue, // 0xD1A6
          NikonOperationCode.startLiveView, // 直接起景
        ]);
        expect(transport.requests.where((r) => r.params.contains(
                PtpDevicePropCode.liveViewImageSize)), isEmpty,
            reason: '「跟随相机」不写机身菜单既有值');
      });

      test('取景运行中改档:即时写(两码独立,失败互不连坐)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        final baseline = transport.requests.length;
        transport
          ..reply(PtpResponseCode.accessDenied) // 0xD1AC 拒
          ..ok(); // 0xD1BC 通
        controller.setLiveViewQuality(imageSize: 3, compression: 3);
        await pumpEventQueue();
        final writes = transport.requests.skip(baseline).toList();
        expect(writes[0].params, [PtpDevicePropCode.liveViewImageSize]);
        expect(writes[0].dataOut, [3]);
        expect(writes[1].params, [PtpDevicePropCode.liveViewImageCompression]);
        expect(writes[1].dataOut, [3]);
        expect(controller.liveViewImageSize, 3,
            reason: '写被拒本地值保持(尽力而为,重连沿再补)');
      });
    });
}
