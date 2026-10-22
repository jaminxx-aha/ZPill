part of 'remote_controller_test.dart';

void _captureGroups() {
    group('快门码 op 表选择(OpenZCine 全系口径:在册 0x9207 直用)', () {
      test('表在册 0x9207 → 首发直用,零标准码流量', () async {
        transport.ok(data: _deviceInfoDataset(
            ops: [NikonOperationCode.initiateCaptureRecInMedia]));
        await controller.session.getDeviceInfo(); // 连接层已取过,预热缓存
        transport
          ..ok() // 0x9207 直发
          ..ok(); // deviceReady
        final c = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c;
        expect(transport.count(PtpOperationCode.initiateCapture), 0,
            reason: '在册即直用,不试标准码');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
      });

      test('表不含 0x9207(STA 小表人设)→ 标准码先行,被拒回退 0x9207',
          () async {
        transport.ok(data: _deviceInfoDataset(ops: [PtpOperationCode.getObject]));
        await controller.session.getDeviceInfo();
        transport
          ..reply(PtpResponseCode.generalError) // 0x100E:被拒
          ..ok() // 0x9207 回退成功
          ..ok(); // deviceReady
        final c = controller.capture();
        await pumpEventQueue();
        delay.release();
        await c;
        expect(transport.count(PtpOperationCode.initiateCapture), 1);
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
        expect(controller.error, isNull);
      });
    });
    group('拍摄模式跟随与切换(0xD1A6 镜像;2026-10-11 Zf USB 实证:两方向都'
        '可覆写、拍照门跟镜像值;录像门跟物理拨杆硬互锁,开录时才拒)', () {
      test('连接沿初读:0xD1A6=1 → 视频;表外方言值(2)不猜 → null 本地回落',
          () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.video);
        expect(controller.dialMode, CaptureMode.video);
        expect(controller.modeOverridden, isFalse);

        // 重连报表外值(未来机身第三态/方言):已知值不清,宁缺不错。
        conn.statesCtrl.add(CameraLinkState.reconnecting);
        await pumpEventQueue();
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 2);
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.video,
            reason: '表外值不猜也不闪清:保持已知态');
      });

      test('0x4006(0xD1A6)事件 → 模式跟随(拨杆翻转实时上屏)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // d1a6=0 照片档
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.photo);

        // 拨杆拨到视频档:事件 → 定向读跟随(+ 模式翻转沿补刷参数:
        // 照片块 + 视频块,拨到视频档要拉整条视频参数链)
        transport.ok(data: Uint8List.fromList([1]));
        _scriptParamsVideo(transport); // 张数链首 + 照片参数 + 视频参数族 + 0xD054
        transport.eventCtrl.add(const PtpEvent(
            code: PtpEventCode.devicePropChanged,
            transactionId: 0xFFFFFFFF,
            params: [PtpDevicePropCode.liveViewSelector]));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(controller.cameraMode, CaptureMode.video);
        expect(controller.dialMode, CaptureMode.video);
      });

      test('0x4006(0xD1F1)事件 → 张数轻量刷新(官方推送通道,150ms 合并)',
          () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.shotsRemaining, 1234);

        // 机身侧计数变化(拍摄/改画质/换卡)→ 相机 1s 巡检推 0x4006 →
        // 合并窗后单笔裸读跟值(不落参数目录的丢弃哨兵)。
        final before = transport.count(PtpOperationCode.getDevicePropValue);
        transport.ok(data: _u32Bytes(999));
        transport.eventCtrl.add(const PtpEvent(
            code: PtpEventCode.devicePropChanged,
            transactionId: 0xFFFFFFFF,
            params: [PtpDevicePropCode.exposureRemaining]));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(controller.shotsRemaining, 999);
        expect(transport.count(PtpOperationCode.getDevicePropValue), before + 1,
            reason: '合并窗内只发一笔裸读');
      });

      test('模式翻转沿作废旧档口径张数/可录时长(0xD1F1 视频档被录像估算'
          '污染,切回照片沿先闪旧值 4197 再被链首新鲜读纠正 → 清空等新鲜读)',
          () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // d1a6=0 照片档,链首张数 1234
        await pumpEventQueue();
        expect(controller.shotsRemaining, 1234);
        expect(controller.cameraMode, CaptureMode.photo);

        // 视频档帧头 @816 带剩余可录 → 胶囊口径就位。
        controller.engine.header.value = parseLiveViewHeader(
            _minimalHeaderFrame(recording: false, videoRemainingMs: 61234));
        expect(controller.videoRemainingMs, 61234);

        // 拨杆翻到视频档:定向读 0xD1A6=1 → 换档沿把张数/可录一并作废
        // (张数是旧档口径,视频档的 0xD1F1 是录像估算假张数,宁缺不错)。
        transport.ok(data: Uint8List.fromList([1]));
        await controller.refreshCameraMode(triggerRefresh: false);
        expect(controller.cameraMode, CaptureMode.video);
        expect(controller.shotsRemaining, isNull,
            reason: '旧档张数不得带进视频档');
        expect(controller.videoRemainingMs, isNull,
            reason: '照片档遗留的时长同沿作废');

        // 同档复读零动作:回填值不被误清(_setCameraMode 只在翻转沿动)。
        controller.shotsRemaining = 4197;
        transport.ok(data: Uint8List.fromList([1]));
        await controller.refreshCameraMode(triggerRefresh: false);
        expect(controller.cameraMode, CaptureMode.video);
        expect(controller.shotsRemaining, 4197,
            reason: '同档复读不触发换档沿,已回填值保留');
      });

      test('switchMode(视频→照片):接管 + 停景 + 写 0xD1A6=0 + 起景 + 刷参',
          () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.video);

        transport
          ..ok() // 0x90C2(1) 接管(顺带 engine.remoteHeld)
          ..ok() // 0x9202 停景
          ..ok() // 0x1016 写 0xD1A6=0
          ..ok() // 0x9201 起景
          ..ok(data: _fakeFrame()); // 首帧
        _scriptParams(transport); // 刷参块(模式族属性连片变)
        final chainStart = transport.requests.length;
        expect(await controller.switchMode(CaptureMode.photo), isTrue);
        expect(controller.error, isNull);

        expect(controller.cameraMode, CaptureMode.photo);
        expect(controller.modeOverridden, isTrue,
            reason: '软件态(照片)≠ 拨杆真档(视频)');
        expect(controller.dialMode, CaptureMode.video,
            reason: '覆写期拨杆真档不可见,不被软件态污染');
        expect(controller.takeoverActive, isTrue);
        expect(controller.engine.remoteHeld, isTrue,
            reason: '接管持有期自愈梯不得碰 0x90C2');
        // 探针实证序:0x90C2(1) → 0x9202 → 写 D1A6 → 0x9201 → 首帧 → 参数
        expect(
            transport.requests
                .skip(chainStart)
                .map((r) => r.opcode)
                .take(5),
            [
              NikonOperationCode.changeCameraMode,
              NikonOperationCode.endLiveView,
              PtpOperationCode.setDevicePropValue,
              NikonOperationCode.startLiveView,
              NikonOperationCode.getLiveViewImageEx,
            ],
            reason: '停景后写、原生档起景');
        final write = transport.requests.singleWhere(
            (r) => r.opcode == PtpOperationCode.setDevicePropValue);
        expect(write.params, [PtpDevicePropCode.liveViewSelector]);
        expect(write.dataOut, [0]);
      });

      test('switchMode 写被拒(0x200F)→ 回滚起景 + 会话级缓存,两方向早退提示',
          () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();

        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..reply(PtpResponseCode.accessDenied) // 0x1016 写被拒
          ..ok() // 0x9201 回滚起景
          ..ok(data: _fakeFrame()); // 首帧
        expect(await controller.switchMode(CaptureMode.photo), isFalse);
        await pumpEventQueue();
        expect(controller.modeWriteRejected, isTrue);
        expect(controller.error?.key, 'remote.errModeSwitchFail');
        expect(controller.cameraMode, CaptureMode.video, reason: '写被拒模式不变');
        expect(controller.liveViewActive, isTrue, reason: '停景已发生,回滚起回');

        // 缓存生效:本会话内两方向都不再撞写(早退 + 拨杆提示)
        final baseline = transport.requests.length;
        expect(await controller.switchMode(CaptureMode.photo), isFalse);
        expect(controller.error?.key, 'remote.errModeSwitchRefused');
        expect(transport.requests.length, baseline);
      });

      test('自然照片档 switchMode(视频)→ 双向可切(2026-10-11 R1:去方向门,'
          '覆写两向都被接受;录像门跟物理拨杆,开录时才拒)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn); // d1a6=0 照片档
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.photo);

        transport
          ..ok() // 0x90C2(1) 接管
          ..ok() // 0x9202 停景
          ..ok() // 0x1016 写 0xD1A6=1
          ..ok() // 0x9201 起景
          ..ok(data: _fakeFrame()); // 首帧
        _scriptParamsVideo(transport); // 切到视频档:刷参 = 照片 + 视频族 + 尾
        final chainStart = transport.requests.length;
        expect(await controller.switchMode(CaptureMode.video), isTrue);
        expect(controller.error, isNull);
        expect(controller.cameraMode, CaptureMode.video);
        expect(controller.modeOverridden, isTrue);
        expect(controller.dialMode, CaptureMode.photo,
            reason: '拨杆真档不动:覆写的是软件态');
        expect(
            transport.requests
                .skip(chainStart)
                .map((r) => r.opcode)
                .take(5),
            [
              NikonOperationCode.changeCameraMode,
              NikonOperationCode.endLiveView,
              PtpOperationCode.setDevicePropValue,
              NikonOperationCode.startLiveView,
              NikonOperationCode.getLiveViewImageEx,
            ]);
        final write = transport.requests.singleWhere(
            (r) => r.opcode == PtpOperationCode.setDevicePropValue);
        expect(write.dataOut, [1], reason: '写 0xD1A6=1(视频)');
      });

      test('覆写态解除接管 → 释放后读回拨杆真档对表(覆写死亡,读值不再被'
          '软件态遮蔽)', () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..ok() // 0x1016 D1A6=0
          ..ok() // 0x9201
          ..ok(data: _fakeFrame());
        _scriptParams(transport);
        expect(await controller.switchMode(CaptureMode.photo), isTrue);

        transport
          ..ok() // 0x90C2(0) 解除
          ..ok(data: Uint8List.fromList([1])); // 释放后读回 D1A6:拨杆=视频
        _scriptParamsVideo(transport); // 读回翻转沿补刷(photo+video+尾)
        await controller.releaseTakeover();
        await pumpEventQueue(); // 翻转沿补刷是 unawaited:泵完再断言/teardown
        expect(controller.cameraMode, CaptureMode.video,
            reason: '覆写随解除死亡:读回拨杆真档(覆写期可能被拨过,不猜)');
        expect(controller.dialMode, CaptureMode.video);
        expect(controller.modeOverridden, isFalse);
        expect(controller.engine.remoteHeld, isFalse);
      });

      test('覆写期拨杆被拨到照片档 → 释放读回对表照片(不可凭旧态猜)', () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..ok() // 0x1016 D1A6=0
          ..ok() // 0x9201
          ..ok(data: _fakeFrame());
        _scriptParams(transport);
        expect(await controller.switchMode(CaptureMode.photo), isTrue);
        expect(controller.dialMode, CaptureMode.video); // 我们以为拨杆在视频

        transport
          ..ok() // 0x90C2(0) 解除
          ..ok(data: Uint8List.fromList([0])); // 读回:拨杆其实在照片档
        await controller.releaseTakeover();
        expect(controller.cameraMode, CaptureMode.photo);
        expect(controller.dialMode, CaptureMode.photo);
        expect(controller.modeOverridden, isFalse);
      });

      test('覆写期 0x4006(D1A6)事件 → 读值是软件态回声:零动作,拨杆真档'
          '不被回声污染', () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..ok() // 0x1016 D1A6=0
          ..ok() // 0x9201
          ..ok(data: _fakeFrame());
        _scriptParams(transport);
        expect(await controller.switchMode(CaptureMode.photo), isTrue);

        // 覆写期读 0xD1A6 得软件态回声(与拨杆真档不可分):与已知软件态
        // 相同即零动作 —— 拨杆真档的真相留给释放接管后的读回。
        transport.ok(data: Uint8List.fromList([0]));
        transport.eventCtrl.add(const PtpEvent(
            code: PtpEventCode.devicePropChanged,
            transactionId: 0xFFFFFFFF,
            params: [PtpDevicePropCode.liveViewSelector]));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(controller.cameraMode, CaptureMode.photo);
        expect(controller.modeOverridden, isTrue);
        expect(controller.dialMode, CaptureMode.video,
            reason: '回声不碰拨杆真档');
      });

      test('模式写被拒 → 会话级缓存;重连(新会话)复位再试', () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..reply(PtpResponseCode.accessDenied) // 0x1016 写被拒
          ..ok() // 0x9201 回滚起景
          ..ok(data: _fakeFrame());
        expect(await controller.switchMode(CaptureMode.photo), isFalse);
        await pumpEventQueue();
        expect(controller.modeWriteRejected, isTrue);

        // 重连:新会话再试一次(拒答缓存随连接复位)
        conn.statesCtrl.add(CameraLinkState.reconnecting);
        await pumpEventQueue();
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        expect(controller.modeWriteRejected, isFalse);
        expect(controller.cameraMode, CaptureMode.video);
      });

      test('断链:覆写/切换中/remoteHeld 清,cameraMode 对齐拨杆真档'
          '(覆写随会话死亡)', () async {
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        transport
          ..ok() // 0x90C2(1)
          ..ok() // 0x9202
          ..ok() // 0x1016 D1A6=0
          ..ok() // 0x9201
          ..ok(data: _fakeFrame());
        _scriptParams(transport);
        expect(await controller.switchMode(CaptureMode.photo), isTrue);

        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        expect(controller.modeOverridden, isFalse);
        expect(controller.engine.remoteHeld, isFalse);
        expect(controller.cameraMode, CaptureMode.video,
            reason: '覆写随会话死亡:拨杆真档即真相(不变式:非覆写 ⇒ '
                'cameraMode == dialMode);重连沿串链再对表');
        expect(controller.dialMode, CaptureMode.video);
      });
    });

    test('0x4006 事件(机身拨盘/菜单改动)→ 定向刷新被点名参数;表外码忽略',
        () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();

      // 表外属性码:不触发刷新
      final baseline = transport.requests.length;
      transport.eventCtrl.add(const PtpEvent(
          code: PtpEventCode.devicePropChanged,
          transactionId: 0xFFFFFFFF,
          params: [0x5011]));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(transport.requests.length, baseline,
          reason: '目录外属性(dateTime)不刷新');

      // 目录内:光圈被拨 → 定向重读
      transport.ok(data: _propDescDataset(
          PtpDevicePropCode.fNumber, PtpDataType.uint16, 400,
          enums: [280, 320, 400]));
      transport.eventCtrl.add(const PtpEvent(
          code: PtpEventCode.devicePropChanged,
          transactionId: 0xFFFFFFFF,
          params: [PtpDevicePropCode.fNumber]));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(controller.exposure?.fNumber, 400, reason: '拨盘改动 → 定向刷新');
    });

    test('厂商路由参数:标准码 getSet=false 不影响可写(真机:0x500F 报只读'
        '但 0xD0B4 可写)', () async {
      _scriptParams(transport, readonlyCodes: {
        PtpDevicePropCode.exposureIndex,
        PtpDevicePropCode.exposureTime
      });
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.propWritable(PtpDevicePropCode.exposureIndex), isTrue,
          reason: 'ISO 写走厂商码,标准码 getSet 不作数');
      expect(controller.propWritable(PtpDevicePropCode.exposureTime), isTrue,
          reason: '快门写走厂商码,同上');
    });
    group('连拍按住(OpenZCine shutterPressLatchedBurst 同款)', () {
      test('连续释放档按下:括持(0x90C2[1] + burstNumber 65535)+ 释放;'
          '抬起:0x920C 终止 + 0x90C2[0] 解除', () async {
        // connected 沿串链自动起景(引擎轮询驻停):换 parked 引擎,不与
        // 连拍帧间等待抢门控 delay 的放行。
        controller.dispose();
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
        );
        controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
        // 不启,门控 delay 放行全部留给连拍/快门流程
        _scriptParams(transport, drive: 2); // 释放档 = 高速连拍
        _emitConnected(transport, conn);
        await pumpEventQueue();

        transport
          ..ok() // 0x90C2 [1] 括持
          ..ok() // 0x1016 写 burstNumber 0x5018 = 65535
          ..ok(); // 第 1 帧 0x9207
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(controller.capturing, isTrue, reason: '按住中');

        // 帧间等待挂起(gated delay);抬起 → 终止 + 解除括持
        transport
          ..ok() // 0x920C 终止
          ..ok(); // 0x90C2 [0] 解除
        await controller.captureReleased();
        delay.release(); // 放行帧间等待 → 循环见锁已断,收尾
        await press;

        expect(controller.error, isNull);
        expect(controller.capturing, isFalse);
        expect(transport.count(NikonOperationCode.changeCameraMode), 2);
        final modes = transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
            .toList();
        expect(modes[0].params, [1], reason: '按下开括持');
        expect(modes[1].params, [0], reason: '抬起解除');
        final burst = transport.requests.singleWhere(
            (r) => r.opcode == PtpOperationCode.setDevicePropValue);
        expect(burst.params, [PtpDevicePropCode.burstNumber]);
        expect(burst.dataOut, [0xFF, 0xFF], reason: '连拍上限 65535');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
        expect(transport.count(NikonOperationCode.terminateCapture), 1);
      });

      test('单张释放档按下 = 原单张路径(无括持无终止);抬起静默', () async {
        // 同上:parked 引擎,DeviceReady 轮询的门控放行不被引擎轮询抢走。
        controller.dispose();
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
        );
        controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
        // 不启,门控 delay 放行全部留给连拍/快门流程
        _scriptParams(transport); // 释放档 = 单张
        _emitConnected(transport, conn);
        await pumpEventQueue();

        transport
          ..ok() // 0x9207
          ..ok(); // deviceReady
        final press = controller.capturePressed();
        await pumpEventQueue();
        delay.release(); // DeviceReady 轮询放行
        await press;
        expect(controller.capturing, isFalse);
        expect(transport.count(NikonOperationCode.changeCameraMode), 0);
        expect(transport.count(NikonOperationCode.terminateCapture), 0);
        await controller.captureReleased(); // 无锁:静默零流量
        expect(transport.requests
                .where((r) => r.opcode == NikonOperationCode.terminateCapture),
            isEmpty);
      });

      test('断连即终止连拍状态(链发循环止步)', () async {
        // 同组口径:parked 引擎,链发循环的等待独享门控放行。
        controller.dispose();
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
        );
        controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
        // 不启,门控 delay 放行全部留给连拍/快门流程
        _scriptParams(transport, drive: 0x8010); // 低速连拍
        _emitConnected(transport, conn);
        await pumpEventQueue();

        transport
          ..ok() // 0x90C2 [1]
          ..ok() // burstNumber
          ..ok(); // 第 1 帧
        final press = controller.capturePressed();
        await pumpEventQueue();
        conn.statesCtrl.add(CameraLinkState.disconnected);
        delay.release();
        await press;
        expect(controller.capturing, isFalse);
        expect(controller.linkUp, isFalse);
      });
    });

    test('色温写入:先切 WB=色温档(0x8012)再写 0xD01E(WB 非色温档时联动)',
        () async {
      _scriptParams(transport); // WB desc value = 2(自动)
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x1016 写 0x5005 = 0x8012
        ..ok() // 0x1016 写 0xD01E = 5000
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.wbColorTemp, PtpDataType.uint16, 5000));
      await controller.setParam(PtpDevicePropCode.wbColorTemp, 5000);
      final writes = transport.requests
          .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
          .toList();
      expect(writes[0].params, [PtpDevicePropCode.whiteBalance],
          reason: 'K 值只在 WB=色温档生效,先切档');
      expect(writes[0].dataOut, [0x12, 0x80]);
      expect(writes[1].params, [PtpDevicePropCode.wbColorTemp]);
      expect(writes[1].dataOut, [0x88, 0x13]); // 5000 = 0x1388
      expect(controller.error, isNull);
    });
    group('自拍定时', () {
      test('档位 2s:按下倒计时 2 拍后释放;倒计时中切档取消', () async {
        controller.setSelfTimer(2);
        expect(controller.selfTimerSeconds, 2);

        transport
          ..ok() // 0x9207
          ..ok(); // deviceReady
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, 2);
        delay.release(); // 第 1 秒
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, 1);
        delay.release(); // 第 2 秒 → 倒计时归零,fire() 内的 capture 启动
        await pumpEventQueue();
        delay.release(); // capture 内 DeviceReady 轮询放行
        await press;
        expect(controller.selfTimerCountdown, isNull);
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
            reason: '倒计时走完释放');
        expect(controller.error, isNull);
      });

      test('倒计时中被取消(切档)→ 不释放零流量', () async {
        controller.setSelfTimer(10);
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, 10);
        controller.setSelfTimer(0); // 取消
        delay.release();
        await press;
        expect(controller.selfTimerCountdown, isNull);
        expect(transport.requests
                .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia),
            isEmpty);
      });
    });
    group('B 门/Time:按住开曝光', () {
      /// 门控 delay 专属的替换控制器(引擎 parked,拍摄页不可见):B 门
      /// 按住等待环/退避重试独占门控放行。
      RemoteController bulbController() {
        controller.dispose();
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
        );
        controller.setViewerVisible(false); // 拍摄页不在前台口径:AE 轮询
        // 不启,门控 delay 放行全部留给连拍/快门流程
        return controller;
      }

      test('快门值 Bulb(0xFFFFFFFF):按下释放不等待,抬起 0x920C 结束', () async {
        bulbController();
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        // 快门值直接置 Bulb 哨兵(0xD100 打包分数空间)
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);

        transport
          ..ok() // 0x9207(Bulb 开)
          ..ok(); // 0x920C(抬起结束)
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(controller.capturing, isTrue, reason: '按住中 = 曝光开着');
        await controller.captureReleased();
        delay.release(); // 按住等待环收口
        await press;
        expect(controller.capturing, isFalse);
        expect(transport.count(NikonOperationCode.terminateCapture), 1);
        expect(controller.error, isNull);
      });

      test('收门链:面板写过 Bulb 哨兵 → 抬起先恢复原快门值再 0x920C', () async {
        bulbController();
        _scriptParams(transport); // 快门读回 1/100s 打包(1<<16|100)
        _emitConnected(transport, conn);
        await pumpEventQueue();
        // 面板选 Bulb:0x1016 写 0xD100 哨兵 + 复读(相机回 Bulb)
        transport
          ..ok()
          ..ok(data: _u32Bytes(0xFFFFFFFF));
        await controller.setParam(PtpDevicePropCode.exposureTime, 0xFFFFFFFF);
        expect(controller.paramProps[PtpDevicePropCode.exposureTime]?.value,
            0xFFFFFFFF);

        transport
          ..ok() // 0x9207(Bulb 开)
          ..ok() // 收门步①:0xD100 恢复 1/100s
          ..ok(); // 收门步②:0x920C
        final press = controller.capturePressed();
        await pumpEventQueue();
        await controller.captureReleased();
        delay.release(); // 按住等待环收口
        await press;
        final writes = transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
            .toList();
        expect(writes.map((w) => w.params).toList(), [
          [PtpDevicePropCode.stillShutterSpeed],
          [PtpDevicePropCode.stillShutterSpeed],
        ], reason: '面板写 Bulb + 收门恢复,都走 0xD100');
        expect(writes[0].dataOut, _u32Bytes(0xFFFFFFFF));
        expect(writes[1].dataOut, _u32Bytes(1 << 16 | 100),
            reason: '收门恢复 = 写前快门值(1/100s 打包)');
        expect(transport.count(NikonOperationCode.terminateCapture), 1);
        expect(controller.paramProps[PtpDevicePropCode.exposureTime]?.value,
            1 << 16 | 100,
            reason: '收门后快门对表回 1/100s(乐观更新)');
        expect(controller.error, isNull);
      });

      test('收门忙等:0x920C 撞 0xA200 ×2 → 500/1000ms 退避重试后收门', () async {
        bulbController();
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);

        transport
          ..ok() // 0x9207(Bulb 开)
          ..reply(NikonResponseCode.bulbReleaseBusy) // 0x920C #1:B 门进行中
          ..reply(NikonResponseCode.bulbReleaseBusy) // #2:仍忙
          ..ok(); // #3:收门成功
        final press = controller.capturePressed();
        await pumpEventQueue();
        final released = controller.captureReleased();
        await pumpEventQueue(); // #1 忙 → 排 500ms 退避门
        delay.release(); // 按住等待环(先入队的门)收口 press 任务
        await pumpEventQueue();
        delay.release(); // 500ms 退避到点 → #2 忙 → 排 1000ms 退避门
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.terminateCapture), 2);
        delay.release(); // 1000ms 退避到点 → #3 成功
        await pumpEventQueue();
        await released;
        await press;
        expect(transport.count(NikonOperationCode.terminateCapture), 3,
            reason: '首发 + 2 次忙退避重试');
        expect(controller.error, isNull);
        expect(controller.capturing, isFalse);
      });

      test('收门预算耗尽:0x920C 恒 0xA200 → 1+3 次后如实报错;再点一次'
          '快门转为收门重试并成功', () async {
        bulbController();
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);

        transport
          ..ok() // 0x9207(Bulb 开)
          ..reply(NikonResponseCode.bulbReleaseBusy) // ×4 全忙(1 + 3 重试)
          ..reply(NikonResponseCode.bulbReleaseBusy)
          ..reply(NikonResponseCode.bulbReleaseBusy)
          ..reply(NikonResponseCode.bulbReleaseBusy);
        final press = controller.capturePressed();
        await pumpEventQueue();
        final released = controller.captureReleased();
        await pumpEventQueue(); // #1 忙 → 500ms 门
        delay.release(); // 按住等待环收口
        await pumpEventQueue();
        delay.release(); // 500ms → #2 忙 → 1000ms 门
        await pumpEventQueue();
        delay.release(); // 1000ms → #3 忙 → 2000ms 门
        await pumpEventQueue();
        delay.release(); // 2000ms → #4 忙 → 预算耗尽
        await pumpEventQueue();
        await released;
        await press;
        expect(transport.count(NikonOperationCode.terminateCapture), 4,
            reason: '首发 + 3 次指数退避重试后停手');
        expect(controller.error?.key, 'remote.errBulbCloseBusy');
        expect(controller.capturing, isFalse);

        // 再点一次快门:不另开曝光,直接再试收门链(恢复路径)
        transport.ok(); // 0x920C 这次成功
        await controller.capturePressed();
        expect(transport.count(NikonOperationCode.terminateCapture), 5);
        expect(
            transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
            reason: '重试收门不另开曝光(0x9207 只有开拍那一次)');
        expect(controller.error, isNull, reason: '收门成功清错');
      });

      test('定时 B 门(自拍 × Bulb):倒计时到点开门 → 曝光同时长倒计时 → '
          '到点自动收门', () async {
        bulbController();
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);
        controller.setSelfTimer(2);

        transport
          ..ok() // 0x9207(自拍倒计时到点 → 开门)
          ..ok(); // 0x920C(曝光倒计时到点 → 自动收门)
        final press = controller.capturePressed();
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, 2);
        delay.release(); // 自拍第 1 秒
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, 1);
        delay.release(); // 自拍第 2 秒 → 开门,曝光倒计时起步
        await pumpEventQueue();
        expect(controller.selfTimerCountdown, isNull);
        expect(controller.capturing, isTrue, reason: '曝光开着');
        expect(controller.bulbExposureCountdown, 2);
        delay.release(); // 曝光第 1 秒
        await pumpEventQueue();
        expect(controller.bulbExposureCountdown, 1);
        delay.release(); // 曝光第 2 秒 → 到点自动收门
        await pumpEventQueue();
        await press;
        expect(controller.bulbExposureCountdown, isNull);
        expect(controller.capturing, isFalse);
        expect(transport.count(NikonOperationCode.terminateCapture), 1,
            reason: '自动收门 = 0x920C');
        expect(controller.error, isNull);
      });

      test('定时 B 门:曝光倒计时中抬起 → 立即手动收门(不等定时)', () async {
        bulbController();
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);
        controller.setSelfTimer(2);

        transport
          ..ok() // 0x9207
          ..ok(); // 0x920C(手动收门)
        final press = controller.capturePressed();
        await pumpEventQueue();
        delay.release(); // 自拍第 1 秒
        await pumpEventQueue();
        delay.release(); // 自拍第 2 秒 → 开门
        await pumpEventQueue();
        expect(controller.bulbExposureCountdown, 2);
        await controller.captureReleased(); // 抬起:立即收门
        delay.release(); // 曝光倒计时挂起的 tick 收口(环退出)
        await press;
        expect(transport.count(NikonOperationCode.terminateCapture), 1);
        expect(controller.bulbExposureCountdown, isNull);
        expect(controller.capturing, isFalse);
        expect(controller.error, isNull);
      });

      test('capture() 直呼(音量键快门路径)遇 Bulb 档:本地拒绝指路,'
          '零流量不开无人收门的曝光', () async {
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);
        await controller.capture();
        expect(controller.notice?.key, 'remote.errBulbShutter');
        expect(controller.error, isNull);
        expect(
            transport.requests.where((r) =>
                r.opcode == NikonOperationCode.initiateCaptureRecInMedia),
            isEmpty,
            reason: '不发票:点按即走的曝光开了没人收门');
        expect(controller.capturing, isFalse);
      });

      test('capture 落定等待:DeviceReady 回 0xA200(B 门曝光中)→ 忙继续等'
          '而非异常收口', () async {
        // 引擎未启动(无连接串链),门控 delay 独占给落定轮询
        transport
          ..ok() // 0x9207
          ..reply(NikonResponseCode.bulbReleaseBusy) // DeviceReady #1:B 门忙
          ..ok(); // DeviceReady #2:就绪
        final capture = controller.capture();
        await pumpEventQueue();
        delay.release(); // 第 1 轮 300ms → 0xA200 → false 继续等
        await pumpEventQueue();
        delay.release(); // 第 2 轮 → true 收口
        await capture;
        expect(transport.count(NikonOperationCode.deviceReady), 2,
            reason: '0xA200 视为忙继续等(旧口径异常即收口,只查 1 次)');
        expect(controller.error, isNull);
      });
    });
    group('录制(0x920A/0x920B)', () {
      test('取景中起录/停录;事件对齐状态', () async {
        // 起录/停录(取景前置在 controller 内检查 liveViewActive —— 测试
        // 用引擎状态伪造太重,直接验证事件对齐与 op 形态)
        transport
          ..ok() // 0x920A
          ..ok(); // 0x920B
        // liveViewActive 需要 engine running —— 用事件驱动状态验证
        transport.eventCtrl.add(const PtpEvent(
            code: NikonEventCode.movieRecordStarted, transactionId: 0xFFFFFFFF));
        await pumpEventQueue();
        expect(controller.recording, isTrue);
        expect(controller.recordingSince, isNotNull);
        transport.eventCtrl.add(const PtpEvent(
            code: NikonEventCode.movieRecordComplete, transactionId: 0xFFFFFFFF));
        await pumpEventQueue();
        expect(controller.recording, isFalse);
        expect(controller.recordingSince, isNull);
      });

      test('未开取景点录制 → 提示不发', () async {
        await controller.toggleRecord();
        expect(controller.error?.key, 'remote.errRecordNeedsViewfinder');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.startMovieRecInCard),
            isEmpty);
      });

      test('帧头录制态同步(@828):机身自启录制对齐;停止帧复位', () async {
        controller.engine.header.value =
            parseLiveViewHeader(_minimalHeaderFrame(recording: true));
        expect(controller.recording, isTrue);
        expect(controller.recordingSince, isNotNull);

        controller.engine.header.value =
            parseLiveViewHeader(_minimalHeaderFrame(recording: false));
        expect(controller.recording, isFalse);
        expect(controller.recordingSince, isNull);
      });

      test('帧头视频剩余可录(@816)同步:>0 认有效,0/缺席清空', () async {
        controller.engine.header.value = parseLiveViewHeader(
            _minimalHeaderFrame(recording: false, videoRemainingMs: 61234));
        expect(controller.videoRemainingMs, 61234);

        // 0 = 本帧无效 → 清空(官方标录制态有效,态外可能恒 0)。
        controller.engine.header.value =
            parseLiveViewHeader(_minimalHeaderFrame(recording: false));
        expect(controller.videoRemainingMs, isNull);

        // >7500000 越界在解析层已弃 → 同清空。
        controller.engine.header.value = parseLiveViewHeader(
            _minimalHeaderFrame(recording: false, videoRemainingMs: 0xFFFFFFFF));
        expect(controller.videoRemainingMs, isNull);
      });
    });
    group('间隔拍摄', () {
      test('1 张轮:探就绪(0x90C8)→ 0x9207 → 落地轮询 → 完成摘要', () async {
        transport
          ..ok() // 调度就绪探测(0x90C8)
          ..ok() // 0x9207(无 op 表缓存 → 现代面直发)
          ..ok(); // 落地轮询 deviceReady
        controller.startInterval(intervalSeconds: 5, shotCount: 1);
        await pumpEventQueue();
        expect(controller.intervalStatus, IntervalometerStatus.running);
        expect(controller.capturing, isTrue, reason: '单拍在途(芯随拍闪忙)');

        delay.release(); // 落地轮询节拍到点
        await controller.intervalDone;
        expect(controller.intervalStatus, IntervalometerStatus.stopped);
        expect(controller.intervalTaken, 1);
        expect(controller.capturing, isFalse);
        expect(controller.notice?.key, 'remote.ivDoneAll');
        expect(transport.count(NikonOperationCode.deviceReady), 2,
            reason: '调度探测 + 落地轮询各一次');
        expect(
            transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
        expect(controller.error, isNull);
      });

      test('忙超时跳拍:探测窗内恒忙(0x2019)→ 跳过本拍继续轮', () async {
        controller.intervalometer.readyPolls = 2; // 拨小探测预算
        transport
          ..reply(PtpResponseCode.deviceBusy) // 探测 1:忙
          ..reply(PtpResponseCode.deviceBusy) // 探测 2:忙 → 预算尽
          ..ok() // 第 2 拍探测:就绪
          ..ok() // 0x9207
          ..ok(); // 落地轮询
        controller.startInterval(intervalSeconds: 5, shotCount: 2);
        await pumpEventQueue();
        delay.release(); // 探测节拍
        await pumpEventQueue();
        expect(controller.intervalAttempted, 1, reason: '跳拍已记账');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 0,
            reason: '忙超时不发快门');

        delay.release(); // 间隔到点 → 第 2 拍
        await pumpEventQueue();
        delay.release(); // 第 2 拍落地轮询
        await controller.intervalDone;
        expect(controller.intervalTaken, 1);
        expect(controller.intervalFailed, 1);
        expect(controller.notice?.key, 'remote.ivDone');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1);
      });

      test('连续失败自停:3 拍全拒 → 自动停 + 真因摘要', () async {
        for (var i = 0; i < 3; i++) {
          transport
            ..ok() // 探测:就绪
            ..reply(PtpResponseCode.deviceBusy) // 0x9207 忙(非码级,不回落)
            ..reply(PtpResponseCode.deviceBusy); // 0xD102 WarningStatus 读拒
        }
        controller.startInterval(intervalSeconds: 5, shotCount: 10);
        await pumpEventQueue(); // 第 1 拍失败
        delay.release(); // 间隔 → 第 2 拍
        await pumpEventQueue();
        delay.release(); // 间隔 → 第 3 拍
        await controller.intervalDone;
        expect(controller.intervalStatus, IntervalometerStatus.stopped);
        expect(controller.intervalAttempted, 3);
        expect(controller.intervalTaken, 0);
        expect(controller.notice?.key, 'remote.ivAutoStop');
      });

      test('启动互锁:B 门 / 录像中 / SDRAM 直拍 / 未连接 全拒(零流量)',
          () async {
        // B 门(快门值 Bulb 哨兵)
        controller.paramProps[PtpDevicePropCode.exposureTime] =
            const PropState(value: 0xFFFFFFFF);
        controller.startInterval(intervalSeconds: 5, shotCount: 1);
        expect(controller.intervalStatus, IntervalometerStatus.idle);
        expect(controller.notice?.key, 'remote.ivBulbOpen');
        controller.paramProps.clear();

        controller.recording = true;
        controller.startInterval(intervalSeconds: 5, shotCount: 1);
        expect(controller.intervalStatus, IntervalometerStatus.idle);
        expect(controller.notice?.key, 'remote.ivRecordingBusy');
        controller.recording = false;

        controller.sdramCapture = true;
        controller.startInterval(intervalSeconds: 5, shotCount: 1);
        expect(controller.intervalStatus, IntervalometerStatus.idle);
        expect(controller.notice?.key, 'remote.ivSdramBusy');
        controller.sdramCapture = false;

        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        controller.startInterval(intervalSeconds: 5, shotCount: 1);
        expect(controller.intervalStatus, IntervalometerStatus.idle);
        expect(controller.notice?.key, 'remote.ivNotConnected');
        expect(transport.requests, isEmpty, reason: '全部本地拒绝零流量');
      });

      test('断链自动停:间隔等待在途掉线 → 调度即停,横幅让位连接指引',
          () async {
        transport
          ..ok() // 探测
          ..ok() // 0x9207
          ..ok(); // 落地轮询
        controller.startInterval(intervalSeconds: 5, shotCount: 3);
        await pumpEventQueue();
        delay.release(); // 第 1 拍落地
        await pumpEventQueue();
        expect(controller.intervalTaken, 1);

        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue(); // 状态沿 → _invalidate → 调度停
        await controller.intervalDone;
        expect(controller.intervalStatus, IntervalometerStatus.stopped);
        expect(controller.intervalAttempted, 1);
        expect(controller.notice, isNull, reason: '断链清横幅,「未连接」独占');
      });

      test('运行中快门让位:capture() 本地拒绝零流量;停轮后恢复手动',
          () async {
        transport
          ..ok() // 探测
          ..ok() // 0x9207
          ..ok(); // 落地轮询
        controller.startInterval(intervalSeconds: 5, shotCount: 2);
        await pumpEventQueue();
        delay.release(); // 第 1 拍落地 → 间隔等待
        await pumpEventQueue();
        expect(controller.intervalTaken, 1);

        final requestsBefore = transport.requests.length;
        await controller.capture();
        expect(controller.notice?.key, 'remote.ivShutterYield');
        expect(transport.requests.length, requestsBefore, reason: '零流量');

        controller.stopInterval();
        await controller.intervalDone;
        expect(controller.notice?.key, 'remote.ivStoppedAll');
        expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
            reason: '停轮后未补拍');
      });
    });
}
