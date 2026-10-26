part of 'remote_controller_test.dart';

void _propGroups() {
    group('APP 接管控制(0x90C2 remote 模式,影控台同款)', () {
      test('启用 → 0x90C2 [1] + 状态;解除 → [0]', () async {
        transport.ok(); // 0x90C2 [1]
        expect(await controller.enableTakeover(), isTrue);
        expect(controller.takeoverActive, isTrue);
        final enable = transport.requests
            .singleWhere((r) => r.opcode == NikonOperationCode.changeCameraMode);
        expect(enable.params, [1]);

        transport.ok(); // 0x90C2 [0]
        await controller.releaseTakeover();
        expect(controller.takeoverActive, isFalse);
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .last
                .params,
            [0]);
      });

      test('启用被拒(0xA003 释放/AF 中)→ false + 友好提示', () async {
        transport.reply(NikonResponseCode.changeCameraModeFailed);
        expect(await controller.enableTakeover(), isFalse);
        expect(controller.takeoverActive, isFalse);
        expect(controller.error?.key, 'remote.takeoverFail');
        expect(controller.error?.args?['e'], 'remote.hintModeSwitchFailed');
      });

      test('未连接启用 → 提示不发', () async {
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        expect(await controller.enableTakeover(), isFalse);
        expect(transport.requests, isEmpty);
      });

      test('断链时持有接管 → 重连后防御性解除(拨盘不留锁)', () async {
        transport.ok(); // 启用接管
        await controller.enableTakeover();
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        expect(controller.takeoverActive, isFalse, reason: '断链即失效');

        // 生产链建模:断链 teardown 即 session.close()(camera_connection
        // 顺序),remote 旗标随链复位 —— 否则重连沿会把它误读作「连接流
        // 已进 remote 模式」而跳过防御性解除。(会话未 Open 时 close 不
        // 下链路,无 closeSession 应答可消费。)
        await controller.session.close();

        // 重连:先防御性解除,再全量刷参
        transport.ok(); // 0x90C2 [0]
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        final modes = transport.requests
            .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
            .toList();
        expect(modes, hasLength(2));
        expect(modes[1].params, [0], reason: '重连后防御性解除 remote 模式');
        expect(controller.exposure?.fNumber, 280, reason: '解除后照常刷参');
      });

      test('USB 连接流括号 1→0 全通 → 接管从 OFF 起步(连接即及时取景)'
          '(OpenZCine 效果,2026-10-07 v8/v9 真机定案)', () async {
        // 生产链建模:USB 连接流 enableAppControl(remoteLatch) 的
        // 0x90C2(1)→(0) 开闩括号 —— 闩单向,退步不关门;remote 持有态
        // 才是机身停「已连接到计算机」屏的元凶,开闩即还身(已连接屏只
        // 闪一次往返的宽度,机身直回自己的取景屏)。
        transport.reply(PtpResponseCode.operationNotSupported); // 0x9435 拒
        transport.ok(); // 0x90C2 [1] 开闩兜底通
        transport.ok(); // 0x90C2 [0] 括号退步通(还身)
        await controller.session.enableAppControl(remoteLatch: true);
        expect(controller.session.remoteModeActive, isFalse,
            reason: '开闩即还身,remote 不持有');

        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.takeoverActive, isFalse,
            reason: '连接流已还身,接管芯片从 OFF 起步');
        expect(controller.exposure?.fNumber, 280, reason: '照常刷参');

        // 未激活:enableTakeover 真发 0x90C2 [1](接管是用户的显式动作)。
        transport.ok();
        expect(await controller.enableTakeover(), isTrue);
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .map((r) => r.params),
            [
              [1],
              [0],
              [1]
            ],
            reason: '连接括号 [1][0] + 用户接管 [1]');
      });

      test('AP 连接沿主动接管:connected 即持 remote + 起景(点连接 = 接管'
          '同意,2026-10-15 用户定案)', () async {
        // 独立假连接:setUp 的默认控制器也订阅 conn.states,共用会把两条
        // connected 链 interleaved 进同一份脚本(参读/起景错位,全假警报)。
        final apConn = FakeConnection();
        final apController = RemoteController(
          session: PtpSession(transport: transport),
          connection: apConn,
          engine: LiveViewEngine(
            session: PtpSession(transport: transport),
            delay: delay.call,
          ),
          delay: delay.call,
          isApMode: () => true,
        );
        addTearDown(apController.dispose);
        _scriptParams(transport);
        _emitConnected(transport, apConn, apTakeover: true);
        await pumpEventQueue();
        expect(apController.takeoverActive, isTrue,
            reason: '连接沿主动持有:机身停「已连接到计算机」屏 + 拨盘锁定');
        expect(apController.session.remoteModeActive, isTrue);
        expect(apController.engine.remoteHeld, isTrue,
            reason: '接管沿同步引擎旗标(自愈梯不再碰 0x90C2)');
        expect(apController.liveViewActive, isTrue,
            reason: '持有态起景为真 —— 连接即取景,不再两步引导');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .map((r) => r.params),
            [[1]],
            reason: '链首只发接管那一发(连接括号的 1→0 在更早的连接流)');
        expect(apController.exposure?.fNumber, 280, reason: '照常刷参');
      });

      test('AP 连接沿开闩被拒 → 不拦链:接管 OFF、起景照发、刷参照常'
          '(引导占位兜底)', () async {
        final apConn = FakeConnection();
        final apController = RemoteController(
          session: PtpSession(transport: transport),
          connection: apConn,
          engine: LiveViewEngine(
            session: PtpSession(transport: transport),
            delay: delay.call,
          ),
          delay: delay.call,
          isApMode: () => true,
        );
        addTearDown(apController.dispose);
        _scriptParams(transport);
        _emitConnected(transport, apConn);
        transport.script.addFirst(
            PtpResult(responseCode: NikonResponseCode.changeCameraModeFailed));
        await pumpEventQueue();
        expect(apController.takeoverActive, isFalse,
            reason: '开闩被拒:接管 OFF,取景失败落引导占位');
        expect(apController.error?.key, 'remote.takeoverFail');
        expect(apController.error?.args?['e'], 'remote.hintModeSwitchFailed',
            reason: 'e 参 = 拨杆引导键(0xA003 changeCameraModeFailed)');
        expect(apController.liveViewActive, isTrue,
            reason: '被拒不拦链:起景照发(真机形态 = 0x9201 假成、帧取失败)');
        expect(apController.exposure?.fNumber, 280, reason: '照常刷参');
      });

      test('AP 取景失败引导:enableTakeoverAndRetryLiveView = 接管持有 + '
          '重发起景(2026-10-15 AP 三轮真机定案)', () async {
        // 连接括号退闩即关 → 未持有态 0x9201 回 OK 假成、帧取 notLiveView;
        // 引导动作 = 接管持有(用户显式同意锁盘/停连接屏)后重发起景,
        // 持有态起景为真。重试仍失败落既有占位,不吞错。
        transport.ok(); // 0x90C2 [1] 接管
        transport.ok(); // 0x9201 起景(持有态为真)
        transport.ok(); // 帧取/收尾 0x9202(时序二选一,均无断言依赖)
        transport.ok(); // 另一笔
        await controller.enableTakeoverAndRetryLiveView();
        expect(controller.takeoverActive, isTrue);
        expect(controller.session.remoteModeActive, isTrue,
            reason: '接管持有(AP 人设:退即关,持有态起景才真)');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .map((r) => r.params),
            [[1]],
            reason: '引导只发接管那一发(连接括号在更早的连接流,不在本账)');
        expect(controller.liveViewActive, isTrue, reason: '重发起景成功');
        expect(controller.engine.remoteHeld, isTrue,
            reason: '接管沿同步引擎旗标(自愈梯不再碰 0x90C2)');
        await controller.toggleLiveView(); // 收尾停景
        expect(controller.liveViewActive, isFalse);
      });

      test('断链悬挂 + 新链括号退步被拒 → 静默对齐接管,不发防御性解除'
          '(不与括号退步重复)', () async {
        transport.ok(); // 启用接管
        await controller.enableTakeover();
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        await controller.session.close(); // teardown 建模(旗标复位)

        // 新链:连接流括号的退步被拒(边沿:机身正忙/模式切换中)→
        // remote 仍持有 —— connected 沿静默对齐接管态;防御性解除不再发
        // (对齐分支先于悬挂分支,重复 [0] 无益;闩已开,门不会丢)。
        transport.reply(PtpResponseCode.operationNotSupported); // 0x9435 拒
        transport.ok(); // 0x90C2 [1] 开闩通
        transport.reply(NikonResponseCode.changeCameraModeFailed); // [0] 退步被拒
        await controller.session.enableAppControl(remoteLatch: true);
        expect(controller.session.remoteModeActive, isTrue,
            reason: '退步被拒 → remote 仍持有');
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.takeoverActive, isTrue,
            reason: '新链的 remote 是连接括号抬的,不是悬挂残留');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .map((r) => r.params),
            [
              [1],
              [1],
              [0]
            ],
            reason: '旧链接管 [1] + 新链括号 [1][0];无防御性解除的第 4 发');
        expect(controller.exposure?.fNumber, 280, reason: '照常刷参');

        // 已激活:enableTakeover 幂等直通,不再发 0x90C2。
        expect(await controller.enableTakeover(), isTrue);
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeCameraMode)
                .length,
            3);
      });

      test('拨盘参数写被拒(0x200F)→ 提示先启用 APP 接管', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        transport.reply(PtpResponseCode.accessDenied); // 0x1016 0xD100 被拒
        await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
        expect(controller.error?.key, 'remote.errPropWriteDial');
        expect(controller.error?.args?['tail'], 'remote.errPropWriteDialLatch');
      });

      test('授权失同步自愈:接管账面开 + 0x200F → 重打闩静默重试(2026-10-26'
          ' 写授权会话级,跨会话/机身退闩后账面失真)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        transport.ok(); // 接管启用 0x90C2(1)
        expect(await controller.enableTakeover(), isTrue);
        transport
          ..reply(PtpResponseCode.accessDenied) // 首写 0x1016 被拒
          ..ok() // 自愈重打闩 0x90C2(1)(幂等)
          ..ok() // 重试 0x1016 通
          ..ok(data: _rawValueBytes(PtpDataType.uint32, 1 << 16 | 100)); // 写后复读 0xD100
        await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
        expect(controller.error, isNull, reason: '自愈成功用户无感');
        expect(controller.takeoverActive, isTrue);
        expect(transport.count(NikonOperationCode.changeCameraMode), 2,
            reason: '启用一发 + 自愈补闩一发,恰两发');
      });

      test('自愈重打闩仍拒 → 账面落闸(面板换出接管门),原 0x200F 上抛', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        transport.ok(); // 接管启用
        expect(await controller.enableTakeover(), isTrue);
        transport
          ..reply(PtpResponseCode.accessDenied) // 首写拒
          ..reply(PtpResponseCode.accessDenied); // 重打闩也拒
        await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
        expect(controller.takeoverActive, isFalse,
            reason: '账面落闸 → needTakeover 翻真,开着的面板自动换出接管门');
        expect(controller.error?.key, 'remote.errPropWriteDial');
      });
    });
    group('曝光变量模式门(OpenZCine stillAllows* 同款;真机:A 模式影控台'
        '同样不能改快门)', () {
      test('A(光圈优先):快门本地拒绝零流量,光圈可调;芯片标「自动」', () async {
        _scriptParams(transport, mode: 3); // A
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.shutterAdjustable, isFalse);
        expect(controller.apertureAdjustable, isTrue);
        expect(controller.paramAutoControlled(PtpDevicePropCode.exposureTime),
            isTrue);
        expect(controller.paramAutoControlled(PtpDevicePropCode.fNumber),
            isFalse);
        expect(controller.propWritable(PtpDevicePropCode.exposureTime), isFalse);

        await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
        // 模式名经 _zh 取渲染形态(键名不再上屏,2026-10-16)
        expect(controller.error?.key, 'remote.errAutoShutter',
            reason: 'A 档快门由相机自动控制(EV 补偿才是用户出口)');
        expect(controller.error?.args?['m'], 'param.modeA');
        expect(
            transport.requests
                .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
            isEmpty,
            reason: '模式门在本地拦下,不再撞 0x200F');
      });

      test('S(快门优先):光圈拒绝,快门可调', () async {
        _scriptParams(transport, mode: 4); // S
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.apertureAdjustable, isFalse);
        expect(controller.shutterAdjustable, isTrue);
        await controller.setParam(PtpDevicePropCode.fNumber, 320);
        expect(controller.error?.key, 'remote.errAutoAperture');
        expect(controller.error?.args?['m'], 'param.modeS');
      });

      test('场景档:快门/光圈/ISO 全由相机拥有', () async {
        _scriptParams(transport, mode: 0x8010); // 自动(场景段)
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.shutterAdjustable, isFalse);
        expect(controller.apertureAdjustable, isFalse);
        expect(controller.isoManualAllowed, isFalse);
        expect(controller.paramAutoControlled(PtpDevicePropCode.exposureIndex),
            isTrue);
      });

      test('U 档/模式未读:不猜锁,交给相机应答', () async {
        _scriptParams(transport, mode: 0x8050); // U1
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.shutterAdjustable, isTrue, reason: 'U 档按内部程序跑');
        expect(controller.apertureAdjustable, isTrue);

        // 模式读不到(desc 与裸值双拒 → 值 null):同样不锁
        final t2 = _ScriptTransport();
        final conn2 = FakeConnection();
        final c2 = RemoteController(
            session: PtpSession(transport: t2),
            connection: conn2,
            // connected 沿串链会自动起景(取帧轮询),停摆 delay 驻住不抢脚本
            engine: LiveViewEngine(
                session: PtpSession(transport: t2), delay: _parkedDelay));
        addTearDown(c2.dispose);
        _scriptParams(t2, modeUnreadable: true);
        _emitConnected(t2, conn2);
        await pumpEventQueue();
        expect(
            c2.paramProps[PtpDevicePropCode.exposureProgramMode]?.value, isNull);
        expect(c2.shutterAdjustable, isTrue);
        expect(c2.apertureAdjustable, isTrue);
      });

      test('自动 ISO 开:写 ISO 直发 0xD0B4(开关与手动值互不干扰,不联动)',
          () async {
        // 末位应答(0xD054 自动 ISO)改 [1](自动开);张数链首读不动
        _scriptParams(transport);
        transport.script.removeLast(); // 0xD054
        transport.ok(data: Uint8List.fromList([1])); // 0xD054 自动开
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.isoAuto, isTrue);
        expect(controller.paramAutoControlled(PtpDevicePropCode.exposureIndex),
            isTrue);
        expect(controller.propWritable(PtpDevicePropCode.exposureIndex), isTrue,
            reason: '自动开仍可调(开关与手动值互不干扰)');

        transport
          ..ok() // 0x1016 直接写 0xD0B4 = 400(不再先发 0xD054=0)
          ..ok(data: _propDescDataset(PtpDevicePropCode.exposureIndex,
              PtpDataType.uint16, 400,
              enums: [100, 200, 400, 800]))
          ..ok(data: _u32Bytes(400));
        await controller.setParam(PtpDevicePropCode.exposureIndex, 400);
        final writes = transport.requests
            .where((r) => r.opcode == PtpOperationCode.setDevicePropValue)
            .toList();
        expect(writes, hasLength(1), reason: '只发 ISO 写,不动自动开关');
        expect(writes[0].params, [PtpDevicePropCode.exposureIndexEx]);
        expect(controller.isoAuto, isTrue, reason: '自动开关保持,互不干扰');
        expect(controller.exposure?.iso, 400);
      });

      test('setIsoAuto(true):写 0xD054=1,ISO 工作值跟随刷新', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();
        expect(controller.isoAuto, isFalse);

        transport
          ..ok() // 0xD054=1
          ..ok(data: _propDescDataset(
              PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 800,
              enums: [100, 200, 400, 800]))
          ..ok(data: _u32Bytes(800)); // 0xD0B5 工作值跟随
        await controller.setIsoAuto(true);
        final write = transport.requests
            .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
        expect(write.params, [PtpDevicePropCode.stillIsoAutoControl]);
        expect(write.dataOut, [1]);
        expect(controller.isoAuto, isTrue);
        expect(controller.exposure?.iso, 800);
      });
    });
    group('控制锁(0x200F 拒绝 → tile 锁标)', () {
      test('非拨盘拥有参数写 0x200F → 错误文案指向 APP 接管(2026-10-17 '
          '写族定案:闩不在拒、闩在即通,EV 0x5010 实证)', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();

        transport.reply(PtpResponseCode.accessDenied); // 0x1016 白平衡被拒
        await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
        expect(controller.error?.key, 'remote.errPropWrite');
        expect(controller.error?.args?['tail'], 'remote.errPropWriteLatch');
        expect(controller.lockedProps,
            contains(PtpDevicePropCode.whiteBalance));
      });

      test('写被拒打锁标;写通解除;断连清空', () async {
        _scriptParams(transport);
        _emitConnected(transport, conn);
        await pumpEventQueue();

        transport.reply(PtpResponseCode.accessDenied); // 0x1016 白平衡被拒
        await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
        expect(controller.lockedProps, contains(PtpDevicePropCode.whiteBalance));

        // 写通:锁解除
        transport
          ..ok()
          ..ok(data: _propDescDataset(
              PtpDevicePropCode.whiteBalance, PtpDataType.uint16, 4,
              enums: [2, 4, 5, 6, 7, 0x8010]));
        await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
        expect(controller.lockedProps, isEmpty);

        // 再拒 → 断连清空
        transport.reply(PtpResponseCode.accessDenied);
        await controller.setParam(PtpDevicePropCode.whiteBalance, 2);
        expect(controller.lockedProps, isNotEmpty);
        conn.statesCtrl.add(CameraLinkState.disconnected);
        await pumpEventQueue();
        expect(controller.lockedProps, isEmpty);
      });
    });

    test('剩余张数:refreshParams 读 0xD1F1 上屏', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.shotsRemaining, 1234, reason: '_scriptParams 末尾预置');
    });

    test('优化校准:FORM 全量入状态 + 自定义/云组真名 0x90CC 拉取'
        '(内置/创意组静态表已有,跳过)', () async {
      _scriptParams(transport,
          picCtrlEnums: [1, 101, 201, 202, 301], picCtrlValue: 201);
      transport
        ..ok(data: _picCtrlData('My Landscape')) // 201
        ..ok(data: _picCtrlData('')) // 202:空名 → 回落静态占位
        ..ok(data: _picCtrlData('Cloud 9')); // 301
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(
          controller
              .paramProps[PtpDevicePropCode.activePicCtrlItem]?.desc?.enumValues,
          [1, 101, 201, 202, 301],
          reason: '相机 FORM 驱动:枚举全量入状态(真机 46 项同理)');
      expect(controller.paramProps[PtpDevicePropCode.activePicCtrlItem]?.value,
          201);
      expect(transport.count(NikonOperationCode.getPictCtrlData), 3,
          reason: '只拉静态表外的槽位:1(标准)/101(Dream)不发 0x90CC');
      expect(
          transport.requests
              .where((r) => r.opcode == NikonOperationCode.getPictCtrlData)
              .map((r) => r.params.first),
          [201, 202, 301],
          reason: '按 FORM 枚举序逐槽位读,params=[槽位,0]');
      expect(
          controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201)
              .key,
          'My Landscape',
          reason: '自定义组真名(机身用户起名)替掉「自定义 1」占位');
      final custom2 = controller
          .displayParamValue(PtpDevicePropCode.activePicCtrlItem, 202);
      expect(custom2.key, 'param.picCtrlCustom',
          reason: '空名(null)回落静态段位格式化(键化分支在控制器)');
      expect(custom2.args?['n'], 2);
      expect(
          controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 301)
              .key,
          'Cloud 9',
          reason: '云组真名替掉「云 1」占位');
      expect(
          controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 1)
              .key,
          'param.standard',
          reason: '静态表标签照常');
      final creative = controller
          .displayParamValue(PtpDevicePropCode.activePicCtrlItem, 101);
      expect(creative.key, 'param.pcDream',
          reason: '创意组走目录键(官方 §9.9.1),段位「创意 {n}」只兜表外值');
      expect(creative.args, isNull);
    });

    test('优化校准:0x90CC 首槽位被拒 → 整组停(不逐个撞),显示回落静态',
        () async {
      _scriptParams(transport, picCtrlEnums: [201, 202], picCtrlValue: 202);
      transport.reply(PtpResponseCode.operationNotSupported);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.getPictCtrlData), 1,
          reason: '首异常即停:202 不再试');
      expect(controller.picCtrlNames, isEmpty);
      expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 202)
          .key, 'param.picCtrlCustom');
      expect(
          controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 202)
              .args?['n'],
          2);
    });

    test('优化校准:断连清缓存;重连重取(每连接一次,重复 connected 不重拉)',
        () async {
      _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
      transport.ok(data: _picCtrlData('My Fav'));
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201)
          .key, 'My Fav');

      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      expect(controller.picCtrlNames, isEmpty, reason: '断连清缓存');
      expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201)
          .key, 'param.picCtrlCustom', reason: '回落静态占位');
      expect(
          controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201)
              .args?['n'],
          1);

      // 重连:再次拉取(新连接档案重建)。
      _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
      transport.ok(data: _picCtrlData('My Fav'));
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.displayParamValue(PtpDevicePropCode.activePicCtrlItem, 201)
          .key, 'My Fav');
      expect(transport.count(NikonOperationCode.getPictCtrlData), 2,
          reason: '两次连接各拉一次');

      // 状态未离开的重复 connected 沿:不重拉(一次性旗标)。
      _scriptParams(transport, picCtrlEnums: [201], picCtrlValue: 201);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(transport.count(NikonOperationCode.getPictCtrlData), 2,
          reason: '同连接内已拉过,不重复');
    });

    test('ObjectAdded → 「已拍摄」提示 + 参数刷新;断连后迟到事件丢弃', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.exposure?.iso, 200);

      // 即拍即览缩略图先行(事件处理序:缩略图 → 参数刷新),再全量刷参
      transport.ok(data: Uint8List.fromList([1, 2, 3]));
      _scriptParams(transport);
      transport.eventCtrl
          .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x1234]));
      await pumpEventQueue();
      expect(controller.notice?.key, 'remote.captured');

      // 断连:_invalidate 清态
      conn.statesCtrl.add(CameraLinkState.failed);
      await pumpEventQueue();
      expect(controller.linkUp, isFalse);
      expect(controller.notice, isNull);
      expect(controller.exposure, isNull);

      // 断连后的迟到事件:notice 不得回屏
      transport.eventCtrl
          .add(const PtpEvent(code: PtpEventCode.objectAdded, transactionId: 0xFFFFFFFF, params: [0x5678]));
      await pumpEventQueue();
      expect(controller.notice, isNull);
    });

    test('未连接 capture:直接提示,不发操作', () async {
      conn.statesCtrl.add(CameraLinkState.disconnected);
      await pumpEventQueue();
      await controller.capture();
      expect(controller.error?.key, 'remote.notConnected');
      expect(transport.requests, isEmpty);
    });

    test('PropDesc 驱动:desc 域入状态(枚举值/可写性可见)', () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      final f = controller.paramProps[PtpDevicePropCode.fNumber]!;
      expect(f.value, 280);
      expect(f.desc?.enumValues, [280, 320, 400]);
      expect(f.desc?.getSet, isTrue);
      expect(controller.exposure?.shutterRaw, 1 << 16 | 100);
      final mode = controller.paramProps[PtpDevicePropCode.exposureProgramMode]!;
      expect(mode.desc?.enumValues, [1, 2, 3, 4, 5]);
      expect(mode.desc?.getSet, isTrue);
    });

    test('PropDesc 不可用退回裸值 0x1015(域未知但值可用)', () async {
      _scriptParamsRawFallback(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.exposure?.fNumber, 280);
      expect(controller.exposure?.shutterRaw, 1 << 16 | 100,
          reason: '快门不读标准码(取值域直供),0xD100 裸值直达');
      expect(controller.exposure?.iso, 200);
      expect(controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value,
          1);
      expect(controller.paramProps[PtpDevicePropCode.fNumber]?.desc, isNull,
          reason: 'PropDesc 拒答后不得残留旧 desc');
    });

    test('门禁开:ISO 写走厂商码 0xD0B4(u32),回读仍读 0x500F', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: delay.call),
        delay: delay.call,
        setPropGate: () => true,
      );
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x1016 写 0xD0B4 = 400(u32)
        ..ok(data: _propDescDataset( // 回读:先 0x500F PropDesc(取值域)
            PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 400,
            enums: [100, 200, 400, 800]))
        ..ok(data: _u32Bytes(400)); // 再 0xD0B5 裸值(值路由)
      await controller.setParam(PtpDevicePropCode.exposureIndex, 400);
      final write = transport.requests
          .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.exposureIndexEx],
          reason: 'Z 系 ISO 写走厂商码');
      expect(write.dataOut, Uint8List.fromList([0x90, 0x01, 0x00, 0x00]));
      expect(controller.exposure?.iso, 400, reason: '屏显以回读为准');
      expect(controller.error, isNull);
    });

    test('门禁开:快门直写 0xD100 打包分数(面板值即写值,无 µs 换算)', () async {
      PtpSession.kSetPropEnabled = true;
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: delay.call),
        delay: delay.call,
        setPropGate: () => true,
      );
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport
        ..ok() // 0x1016 写 0xD100 = (1<<16)|100
        ..ok(data: _u32Bytes(1 << 16 | 100)); // 回读 0xD100 裸值
      await controller.setParam(PtpDevicePropCode.exposureTime, 1 << 16 | 100);
      final write = transport.requests
          .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.stillShutterSpeed],
          reason: 'Z 系快门写走厂商码');
      expect(write.dataOut, Uint8List.fromList([0x64, 0x00, 0x01, 0x00]));
      expect(controller.exposure?.shutterRaw, 1 << 16 | 100);
    });

    test('模式(机顶转盘拥有 → dialOwned):相机报只读(getSet=false)仍可写'
        ' —— 0x500E u16 标准码直发(接管锁转盘后写入,OpenZCine 同款)',
        () async {
      // 真机形态:0x500E 拨盘拥有,相机 PropDesc 上报 getSet=false
      _scriptParams(transport, readonlyCodes: {PtpDevicePropCode.exposureProgramMode});
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
          isTrue,
          reason: 'dialOwned 参数绕过 getSet 门(相机报只读是拨盘语义,'
              '接管后可写)—— 否则芯片置灰点不动(2026-10-06 真机)');

      transport
        ..ok() // 0x1016 写 0x500E = 4(S 档)
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.exposureProgramMode, PtpDataType.uint16, 4,
            getSet: false, enums: [1, 2, 3, 4, 5]));
      await controller.setParam(PtpDevicePropCode.exposureProgramMode, 4);
      final write = transport.requests
          .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.exposureProgramMode]);
      expect(write.dataOut, Uint8List.fromList([0x04, 0x00]));
      expect(
          controller.paramProps[PtpDevicePropCode.exposureProgramMode]?.value, 4);
      expect(controller.error, isNull);
    });

    test('对焦单一芯片:0x500A 镜像移出目录,0xD061 可调(pickValues 直供)',
        () async {
      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(shootingParamByCode.containsKey(PtpDevicePropCode.focusMode),
          isFalse,
          reason: '0x500A 只读镜像移出,避免「对焦/对焦模式」双芯片');
      expect(controller.propWritable(PtpDevicePropCode.stillFocusMode), isTrue,
          reason: '0xD061 pickValues 直供,PropDesc 拒答也可调');
    });

    test('总闸紧急关断:setParam 直接拒绝,零流量', () async {
      PtpSession.kSetPropEnabled = false; // 生产已开,显式关断走分支
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      await controller.setParam(PtpDevicePropCode.fNumber, 320);
      expect(controller.error?.key, 'remote.errWriteKilled');
      expect(transport.requests, isEmpty);
      expect(controller.writing, isFalse);
    });

    test('门禁开:0x1016 裸值写出 + 回读刷新(相机 clamp 以回读为准)', () async {
      PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: delay.call),
        delay: delay.call,
        setPropGate: () => true,
      );

      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();
      expect(controller.canAdjustParams, isTrue);
      expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue);
      expect(controller.propWritable(PtpDevicePropCode.exposureProgramMode),
          isTrue,
          reason: '模式 dialOwned 可写(接管确认后写入,相机侧决定收否)');

      transport
        ..ok() // 0x1016 写 fNumber=320
        ..ok(data: _propDescDataset( // 回读:相机 clamp 到 400
            PtpDevicePropCode.fNumber, PtpDataType.uint16, 400,
            enums: [280, 320, 400]));
      await controller.setParam(PtpDevicePropCode.fNumber, 320);

      final write = transport.requests
          .singleWhere((r) => r.opcode == PtpOperationCode.setDevicePropValue);
      expect(write.params, [PtpDevicePropCode.fNumber]);
      expect(write.dataOut, Uint8List.fromList([0x40, 0x01])); // u16 裸值 320
      expect(controller.exposure?.fNumber, 400, reason: '屏显以回读为准');
      expect(controller.error, isNull);
      expect(controller.writing, isFalse);
    });

    test('门禁开:相机上报只读(getSet=false)→ 拒写(dialOwned 参数除外)',
        () async {
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: delay.call),
        delay: delay.call,
        setPropGate: () => true,
      );

      // 白平衡(菜单级)报只读 → 拒写;光圈(dialOwned)报只读不拦
      _scriptParams(transport, readonlyCodes: {
        PtpDevicePropCode.whiteBalance,
        PtpDevicePropCode.fNumber
      });
      _emitConnected(transport, conn);
      await pumpEventQueue();

      await controller.setParam(PtpDevicePropCode.whiteBalance, 4);
      expect(controller.error?.key, 'remote.errReadOnly');
      expect(
          transport.requests
              .where((r) => r.opcode == PtpOperationCode.setDevicePropValue),
          isEmpty);
      expect(controller.propWritable(PtpDevicePropCode.whiteBalance), isFalse);
      expect(controller.propWritable(PtpDevicePropCode.fNumber), isTrue,
          reason: '拨盘级参数的只读上报是拨盘语义,接管模型覆盖(不拦)');
    });

    test('门禁开:写失败(0x2019 忙)→ 报错,值不漂移', () async {
      PtpSession.kSetPropEnabled = true; // 翻 session 总闸(controller 闸已注入)
      addTearDown(() => PtpSession.kSetPropEnabled = true);
      controller.dispose();
      controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: delay.call),
        delay: delay.call,
        setPropGate: () => true,
      );

      _scriptParams(transport);
      _emitConnected(transport, conn);
      await pumpEventQueue();

      transport.reply(PtpResponseCode.deviceBusy); // 0x1016 忙
      await controller.setParam(PtpDevicePropCode.fNumber, 320);
      expect(controller.error?.key, 'remote.errPropWriteDial',
          reason: '光圈是指令拨盘参数,接管失败文案走拨盘支');
      expect(controller.exposure?.fNumber, 280, reason: '失败后原值不动');
      expect(controller.writing, isFalse);
    });

    test('对焦后拍默认关:0x9207 首参 0xFFFFFFFF(直接释放,OpenZCine 形态)',
        () async {
      transport
        ..ok() // 0x9207 直发(无 op 表缓存 → 默认现代面)
        ..ok(); // deviceReady
      final c = controller.capture();
      await pumpEventQueue();
      delay.release();
      await c;
      expect(
          transport.requests
              .singleWhere(
                  (r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
              .params,
          [0xFFFFFFFF, 0]);
    });

    test('对焦后拍开:首发与缓存直发的 0x9207 都带 CaptureSort 首参',
        () async {
      controller.focusBeforeCapture = true;
      expect(controller.focusBeforeCapture, isTrue);
      transport
        ..ok() // 0x9207(对焦后拍)
        ..ok(); // deviceReady
      final first = controller.capture();
      await pumpEventQueue();
      delay.release();
      await first;

      transport
        ..ok() // 0x9207 直发
        ..ok(); // deviceReady
      final second = controller.capture();
      await pumpEventQueue();
      delay.release();
      await second;

      final mediaOps = transport.requests
          .where((r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia)
          .toList();
      expect(mediaOps, hasLength(2));
      expect(mediaOps[0].params, [0xFFFFFFFE, 0]);
      expect(mediaOps[1].params, [0xFFFFFFFE, 0],
          reason: '缓存码直发路径同样携带');
    });
    group('视频参数写后复读守卫(2026-10-13 探针:Zf 视频曝光写收下但弹回)', () {
      test('写 0xD1A9 成功但读回拨盘值 → notice 明说;读回一致 → 无提示',
          () async {
        // 视频档连接(0xD1A6=1):当前光圈 200(拨盘值)
        _scriptParamsVideo(transport);
        _emitConnected(transport, conn, d1a6: 1);
        await pumpEventQueue();
        expect(controller.cameraMode, CaptureMode.video);

        // 写 280 → 0x1016 OK,复读回 200(弹回)→ notice
        transport
          ..ok() // 0x1016 写 280
          ..ok(data: _propDescDataset(PtpDevicePropCode.movieFnumber,
              PtpDataType.uint16, 200,
              getSet: true, enums: [200, 280])); // 复读回弹值
        await controller.setParam(PtpDevicePropCode.movieFnumber, 280);
        expect(controller.error, isNull);
        expect(controller.notice?.key, 'remote.errPropBounce');

        // 写 200(= 拨盘值)→ 复读一致 → 无守卫提示
        transport
          ..ok() // 0x1016 写 200
          ..ok(data: _propDescDataset(PtpDevicePropCode.movieFnumber,
              PtpDataType.uint16, 200,
              getSet: true, enums: [200, 280]));
        await controller.setParam(PtpDevicePropCode.movieFnumber, 200);
        expect(controller.notice, isNull);
      });
    });
}
