part of 'remote_controller_test.dart';

void _crossGroups() {
    group('断链自动重连沿(2026-10-10)', () {
      test('reconnecting 沿:_invalidate 清态 + reconnecting=true;'
          '引擎停转但末帧保留(页面冻结帧不闪黑)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // 串链自动起景(0x9201 + 首帧)
        await pumpEventQueue();
        expect(controller.linkUp, isTrue);
        expect(controller.exposure?.fNumber, 280);
        expect(controller.liveViewActive, isTrue);
        final frozenFrame = controller.engine.frame.value;
        expect(frozenFrame, isNotNull);

        var notified = 0;
        controller.addListener(() => notified++);
        transport.ok(); // 0x9202(恢复期引擎 stop 尽力)

        conn.statesCtrl.add(CameraLinkState.reconnecting);
        await pumpEventQueue();
        expect(controller.reconnecting, isTrue);
        expect(controller.linkUp, isFalse, reason: '断连收口门闩(迟到值/事件被挡)');
        expect(controller.paramProps, isEmpty);
        expect(controller.exposure, isNull, reason: '参数清态');
        expect(controller.liveViewActive, isFalse, reason: '引擎停转(相机侧收景)');
        expect(controller.engine.frame.value, same(frozenFrame),
            reason: '末帧保留:页面横幅压暗下保留冻结帧等重连');
        expect(notified, greaterThan(0), reason: '_invalidate 通知页面(横幅驱动)');
        expect(transport.count(NikonOperationCode.endLiveView), 1);
      });

      test('reconnecting → connected:旗标清、参数重载、取景自愈重启'
          '(重连成功自动恢复 —— 2026-10-11 修复:connected 沿串链自动起景,'
          '画面就地恢复,不再须退出拍摄页重进)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // 首连:串链起景 + 刷参
        await pumpEventQueue();
        expect(controller.liveViewActive, isTrue);
        transport.ok(); // 0x9202(reconnecting 沿引擎 stop 尽力)
        conn.statesCtrl.add(CameraLinkState.reconnecting);
        await pumpEventQueue();
        expect(controller.reconnecting, isTrue);
        expect(controller.linkUp, isFalse);
        expect(controller.liveViewActive, isFalse, reason: '恢复期引擎停转');

        _scriptParams(transport);
        _emitConnected(transport, conn); // 重连成功:串链再起景 + 再刷参
        await pumpEventQueue();
        expect(controller.reconnecting, isFalse);
        expect(controller.linkUp, isTrue);
        expect(controller.exposure?.fNumber, 280, reason: '重连成功全量刷参');
        expect(controller.liveViewActive, isTrue,
            reason: '重连成功取景自愈重启(画面就地恢复)');
        expect(transport.count(NikonOperationCode.startLiveView), 2,
            reason: '两次 connected 沿各一次 0x9201');
        expect(controller.engine.frame.value, isNotNull,
            reason: '自愈首帧已发布,冻结画面已被替换');
      });

      test('reconnecting → failed:旗标清,终态留给页面弹回(预算耗尽)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        conn.statesCtrl.add(CameraLinkState.reconnecting);
        await pumpEventQueue();
        expect(controller.reconnecting, isTrue);

        conn.statesCtrl.add(CameraLinkState.failed);
        await pumpEventQueue();
        expect(controller.reconnecting, isFalse);
        expect(controller.linkUp, isFalse);
      });

      test('liveViewBusyHold:引擎健康度透传,BUSY 保持沿通知页面(横幅)', () async {
        expect(controller.liveViewBusyHold, isFalse);
        var notified = 0;
        controller.addListener(() => notified++);

        controller.engine.health.value = LiveViewHealth.busy;
        expect(controller.liveViewBusyHold, isTrue);
        expect(notified, 1, reason: '_onEngineHealth → notifyListeners');

        controller.engine.health.value = LiveViewHealth.ok;
        expect(controller.liveViewBusyHold, isFalse);
        expect(notified, 2);
      });
    });
    group('官方指令书候选区接线·控制器(2026-10-13 批:AF 取消/主体追踪/'
        'AE 锁/0xD102/SDRAM 直拍)', () {
      late _ScriptTransport transport;
      late FakeConnection conn;
      late _FakeTransferEngine gallery;
      late RemoteController controller;

      setUp(() {
        transport = _ScriptTransport();
        conn = FakeConnection();
        gallery = _FakeTransferEngine();
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          transferEngine: gallery,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
          aeDelay: _parkedDelay,
        );
        // 5s/120s 真窗拨小:超时分支即时收口,不拖测试钟。
        controller
          ..sdramHandleTimeout = const Duration(milliseconds: 80)
          ..sdramTransferTimeout = const Duration(milliseconds: 80);
      });

      tearDown(() async {
        controller.dispose();
      });

      Future<void> startLiveView() async {
        transport
          ..ok() // 0x9201
          ..ok(data: _fakeFrame()); // 首帧
        await controller.toggleLiveView();
        await pumpEventQueue();
      }

      test('对焦中再点对焦钮 → 零发包 + 如实提示(2026-10-17 真机定案)',
          () async {
        controller.focusing = true;
        await controller.afDriveNow();
        expect(transport.requests, isEmpty,
            reason: 'Zf 对 0x90C1 扣应答至 AF 结束,AF 期间线路被占死,'
                '0x9206 只能排队到 AF 后空放 —— 假动作撤,零流量');
        expect(controller.notice?.key, 'remote.focusInProgress');
        expect(controller.error, isNull);
      });

      test('主体追踪:未开取景 → 拦下不发票', () async {
        await controller.startTracking();
        expect(controller.error?.key, 'remote.errViewfinderOff');
        expect(transport.requests, isEmpty);
      });

      test('主体追踪:AF 区域非「自动」(0x8010 单点)→ notice 指引,不发票',
          () async {
        await startLiveView();
        controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
            const PropState(value: 0x8010);
        await controller.startTracking();
        expect(controller.notice?.key, 'remote.errTrackingNeedsAuto');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.startTracking),
            isEmpty);
      });

      test('主体追踪:启动 → 0x9424 whole-size 中心坐标(无触控点),'
          'tracking=true', () async {
        await startLiveView();
        controller.engine.header.value =
            parseLiveViewHeader(_minimalHeaderFrame(recording: false));
        controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
            const PropState(value: 0x8011);
        transport.ok(); // 0x9424
        await controller.startTracking();
        final req = transport.requests
            .singleWhere((r) => r.opcode == NikonOperationCode.startTracking);
        expect(req.params, [3024, 1700],
            reason: '0.5×6048、0.5×3400(0x9205 同坐标系)');
        expect(controller.tracking, isTrue);
        expect(controller.error, isNull);
      });

      test('主体追踪:停止 → 0x9425 无参,tracking=false', () async {
        await startLiveView();
        controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
            const PropState(value: 0x8011);
        transport
          ..ok() // 0x9424
          ..ok(); // 0x9425
        await controller.startTracking();
        await controller.endTracking();
        expect(transport.count(NikonOperationCode.startTracking), 1);
        final end = transport.requests
            .singleWhere((r) => r.opcode == NikonOperationCode.endTracking);
        expect(end.params, isEmpty);
        expect(controller.tracking, isFalse);
      });

      test('AE 锁:切换写 0x9426 [1,2]/[0,2](探针形),0xD105 读回对表',
          () async {
        transport
          ..ok() // 0x9426 锁
          ..ok(data: Uint8List.fromList([1])) // 0xD105:1=锁定
          ..ok() // 0x9426 解锁
          ..ok(data: Uint8List.fromList([0])); // 读回 0
        await controller.toggleAELock();
        expect(transport.requests[0].opcode, NikonOperationCode.changeAELock);
        expect(transport.requests[0].params, [1, 2]);
        expect(controller.aeLocked, isTrue);
        await controller.toggleAELock();
        expect(transport.requests[2].params, [0, 2]);
        expect(controller.aeLocked, isFalse);
      });

      test('AE 锁:0x200F 拒(WB 非 auto 时机身拒 AWB 锁)→ error,旗标不动',
          () async {
        transport.reply(PtpResponseCode.accessDenied);
        await controller.toggleAELock();
        expect(controller.error?.key, 'remote.errAeLockFail');
        expect(controller.aeLocked, isFalse);
      });

      test('AE 锁:读回与乐观态不一致 → 以读回为准(不亮假锁)', () async {
        transport
          ..ok() // 0x9426 OK
          ..ok(data: Uint8List.fromList([0])); // 0xD105 读回未锁
        await controller.toggleAELock();
        expect(controller.aeLocked, isFalse);
      });

      test('内屏强关:0x9422 [1]/[0] 切换,0xD1BA 读回对表(B 组)', () async {
        transport
          ..ok() // 0x9422 强关
          ..ok(data: Uint8List.fromList([1])) // 0xD1BA:1=已强关
          ..ok() // 0x9422 取消
          ..ok(data: Uint8List.fromList([0])); // 读回 0
        await controller.toggleMonitorOff();
        expect(transport.requests[0].opcode, NikonOperationCode.changeMonitorOff);
        expect(transport.requests[0].params, [1]);
        expect(controller.monitorOff, isTrue);
        await controller.toggleMonitorOff();
        expect(transport.requests[2].params, [0]);
        expect(controller.monitorOff, isFalse);
      });

      test('内屏强关:拒答 → error,旗标不动', () async {
        transport.reply(PtpResponseCode.accessDenied); // 电池耗尽等拒 0x200F
        await controller.toggleMonitorOff();
        expect(controller.error?.key, 'remote.errMonitorOffFail');
        expect(controller.monitorOff, isFalse);
      });

      test('capture 通用错误 + 0xD102 Bit0 → 追加序列错误自愈指引'
          '(官方 §11.7.5:下一次释放自清)', () async {
        transport
          ..reply(NikonResponseCode.hardwareError) // 0x9207 → hint
          ..ok(data: _u32Bytes(0x1)); // 0xD102 Bit0=1
        await controller.capture();
        expect(controller.error?.key, 'remote.errShutterFailCode');
        expect(controller.error?.args?['h'], 'remote.hintHardwareError');
        expect(controller.error?.args?['seq'], 'remote.warnSeqRecover');
      });

      test('capture 通用错误 + 0xD102 无位 → 原错误不动', () async {
        transport
          ..reply(NikonResponseCode.hardwareError)
          ..ok(data: _u32Bytes(0x0));
        await controller.capture();
        expect(controller.error?.key, 'remote.errShutterFailCode');
        expect(controller.error?.args?['h'], 'remote.hintHardwareError');
        expect(controller.error?.args?['seq'], '', reason: '无序列错误位:不带自愈指引');
      });

      test('SDRAM 直拍全链:0x90CB → 手拉事件 0xC101 句柄 → ObjectInfo → '
          '图库入队(gallery)→ 终态 notice', () async {
        controller.sdramCapture = true;
        transport
          ..ok() // 0x90CB AF+SDRAM 一体
          ..ok() // deviceReady → true(settle)
          ..ok(data: _eventExDataset(NikonEventCode.objectAddedInSdram, 0x1234))
          ..ok(data: _objectInfoDataset()); // getObjectInfo(0x1234)
        final capture = controller.capture();
        await pumpEventQueue();
        delay.release(); // DeviceReady 轮询放行
        await capture;
        expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1);
        expect(gallery.enqueued, hasLength(1));
        expect(gallery.enqueued.single.handle, 0x1234);
        expect(gallery.lastDestination, TransferDestination.gallery);
        expect(controller.notice?.key, 'remote.sdramSaved');
        expect(controller.error, isNull);
        expect(controller.capturing, isFalse);
      });

      test('SDRAM 直拍:0xC101 未到(5s 窗)→ notice 如实,不上 error 不入队',
          () async {
        controller.sdramCapture = true;
        transport
          ..ok() // 0x90CB
          ..ok() // deviceReady
          ..ok(data: Uint8List.fromList([0, 0, 0, 0])); // getEventEx 空队列
        final capture = controller.capture();
        await pumpEventQueue();
        delay.release();
        await capture;
        expect(controller.notice?.key, 'remote.errNoSdramObject');
        expect(controller.error, isNull);
        expect(gallery.enqueued, isEmpty);
      });

      test('SDRAM 直拍被拒(0x2005)→ 回落常规 0x9207 入卡 + notice 如实;'
          '模型级拒绝记本连接不再重试', () async {
        controller.sdramCapture = true;
        transport
          ..reply(PtpResponseCode.operationNotSupported) // 0x90CB 被拒
          ..ok() // 0x9207 回落
          ..ok() // deviceReady(settle)
          ..ok() // 第二拍 0x9207 直发
          ..ok(); // deviceReady
        final c1 = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c1;
        expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1);
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
            reason: '回退必须实发 0x9207 —— 照片入卡不丢');
        expect(controller.notice?.key, 'remote.sdramRejected',
            reason: '照片去了卡而非 SDRAM,机制变更必须如实带出');
        expect(controller.notice?.args?['tail'], 'remote.sdramNoRetry');
        expect(controller.error, isNull);
        expect(gallery.enqueued, isEmpty);
        final c2 = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c2;
        expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 1,
            reason: '0x2005 模型个性跨连接稳定,第二拍不再试 0x90CB');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 2,
            reason: '第二拍 0x9207 直发(会话缓存)');
        expect(controller.error, isNull);
      });

      test('SDRAM 直拍状态类拒绝(0x200F)→ 回落但逐拍回试 0x90CB', () async {
        controller.sdramCapture = true;
        transport
          ..reply(PtpResponseCode.accessDenied) // 第一拍 0x90CB(拨杆位)
          ..ok() // 0x9207 回落
          ..ok() // deviceReady
          ..reply(PtpResponseCode.accessDenied) // 第二拍 0x90CB 仍回试
          ..ok() // 0x9207
          ..ok(); // deviceReady
        final c1 = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c1;
        final c2 = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c2;
        expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 2,
            reason: '状态类拒绝(拨杆位)不是模型个性,逐拍回试');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 2,
            reason: '每次回退都要实发 0x9207 —— 照片必须入卡不丢');
        expect(controller.notice?.key, 'remote.sdramRejected');
        expect(controller.error, isNull);
      });

      test('SDRAM 直拍忙(0x2019)不回落:照旧 error,不发票 0x9207', () async {
        controller.sdramCapture = true;
        transport
          ..reply(PtpResponseCode.deviceBusy) // 0x90CB 忙
          ..ok(data: _u32Bytes(0x0)); // 0xD102 序列错误位读(无位 → 原错误)
        await controller.capture();
        expect(controller.error?.key, 'remote.errShutterFail',
            reason: '忙 = 相机没收下命令,回落重拍反而添乱');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 0);
        expect(gallery.enqueued, isEmpty);
      });

      test('SDRAM 直拍 + B 门:本地跳过 0x90CB 零流量,0x9207 开门照旧入卡',
          () async {
        controller.sdramCapture = true;
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);
        transport
          ..ok() // 0x9207(Bulb 开)—— 直拍码被本地门挡下
          ..ok(); // 0x920C(抬起结束)
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.afAndCaptureRecInSdram), 0,
            reason: 'B 门/Time 是直拍族规格死门(0xA008/0xA204,官方 §6.2.4.2/'
                '.3,2026-10-17 真机实证),本地跳过不发冤枉流量');
        expect(controller.notice?.key, 'remote.sdramBulbFallback',
            reason: '改道机制必须如实带出(横幅在曝光开始前显示)');
        await controller.captureReleased();
        delay.release(); // 按住等待环收口
        await press;
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
        expect(transport.count(NikonOperationCode.terminateCapture), 1);
        expect(controller.error, isNull);
      });

      test('断链 → tracking/AE 锁旗标清零(会话级状态不跨会话)', () async {
        await startLiveView();
        controller.paramProps[PtpDevicePropCode.stillFocusMeteringMode] =
            const PropState(value: 0x8011);
        transport
          ..ok() // 0x9424
          ..ok() // 0x9426 锁
          ..ok(data: Uint8List.fromList([1])); // 0xD105 读回
        await controller.startTracking();
        await controller.toggleAELock();
        expect(controller.tracking, isTrue);
        expect(controller.aeLocked, isTrue);
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        expect(controller.tracking, isFalse);
        expect(controller.aeLocked, isFalse);
      });
    });
}
