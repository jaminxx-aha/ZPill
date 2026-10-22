part of 'remote_controller_test.dart';

void _afGroups() {
    group('触控对焦与对焦驱动(候选码,待真机核对)', () {
      late _ScriptTransport transport;
      late FakeConnection conn;
      late RemoteController controller;

      setUp(() {
        transport = _ScriptTransport();
        conn = FakeConnection();
        // 引擎帧轮询/AE 轮询驻停(不抢脚本);控制器 delay 保留门控
        // 供 0x2019 忙退避测试放行。
        controller = RemoteController(
          session: PtpSession(transport: transport),
          connection: conn,
          engine: LiveViewEngine(
              session: PtpSession(transport: transport), delay: _parkedDelay),
          delay: delay.call,
          aeDelay: _parkedDelay,
        );
      });

      tearDown(() async {
        controller.dispose();
      });

      /// 开取景:0x9201 + 首帧(SOF 32×24)→ 帧轮询驻停,帧尺寸已入册。
      Future<void> startLiveView() async {
        transport
          ..ok() // 0x9201
          ..ok(data: _fakeFrame()); // 首帧
        await controller.toggleLiveView();
        await pumpEventQueue();
        expect(controller.frameSize.value, (width: 32, height: 24));
      }

      test('点按 → 0x9205 挪框不自动 AF(2026-10-17 定案)+ 对焦框上屏',
          () async {
        await startLiveView();
        transport.ok(); // changeAfArea
        await controller.touchFocus(0.5, 0.25);
        final af = transport.requests
            .singleWhere((r) => r.opcode == NikonOperationCode.changeAfArea);
        expect(af.params, [16, 6], reason: '0.5×32、0.25×24(无头退回 SOF 帧)');
        expect(transport.count(NikonOperationCode.afDrive), 0,
            reason: '挪框只挪框,不跟发 AF');
        expect(controller.afBox, isNotNull);
        expect(controller.afBox!.nx, 0.5);
        expect(controller.afBox!.ny, 0.25);
        expect(controller.afBox!.focused, isNull, reason: '未对焦:框回未定红');
        expect(controller.error, isNull);
        expect(controller.focusing, isFalse);
      });

      test('帧头在册 → 0x9205 参数用 whole-size 坐标系(6048×3400)', () async {
        await startLiveView();
        controller.engine.header.value =
            parseLiveViewHeader(_minimalHeaderFrame(recording: false));
        transport.ok(); // changeAfArea
        await controller.touchFocus(0.5, 0.25);
        final af = transport.requests
            .singleWhere((r) => r.opcode == NikonOperationCode.changeAfArea);
        expect(af.params, [3024, 850],
            reason: '0.5×6048、0.25×3400(OpenZCine recentre 同坐标系)');
      });

      test('录制被 0xA004 拒(机顶拨杆在照片档)→ 拨杆提示,录制态不变',
          () async {
        await startLiveView();
        transport.reply(NikonResponseCode.invalidStatus); // 0x920A 被拒
        await controller.toggleRecord();
        expect(controller.error?.key, 'remote.errLeverVideo');
        expect(controller.recording, isFalse, reason: '被拒不翻转录制态');
      });

      test('0x9205 忙(0x2019)→ 宽限内逐拍退避静默续发(拉焦轮同款口径)',
          () async {
        await startLiveView();
        // 五连忙(超旧 3 次预算 —— 在途 0x9204 驱动窗可达 2s+):宽限
        // (4s 墙钟)内一律静默续发,第 6 拍成功;超宽限暂停沿走
        // DateTime 真钟,桩测不造假钟不覆盖(拉焦轮宽限用例同政策)。
        for (var i = 0; i < 5; i++) {
          transport.reply(PtpResponseCode.deviceBusy);
        }
        transport.ok(); // changeAfArea 第 6 拍成功(挪框不驱动 AF,无后续应答)
        final f = controller.touchFocus(0.25, 0.25);
        await pumpEventQueue();
        for (var i = 0; i < 5; i++) {
          delay.release(); // 第 1..5 次退避
          await pumpEventQueue();
        }
        await f;
        expect(transport.count(NikonOperationCode.changeAfArea), 6);
        expect(controller.afBox, isNotNull);
        expect(controller.error, isNull);
        expect(controller.notice, isNull, reason: '宽限内静默不提示');
      });

      test('同点再点 = 只驱动 AF 不重发 0x9205(点两下 = 移动 + 对焦);'
          '容差内算同点、大位移算挪框', () async {
        await startLiveView();
        transport
          ..ok() // 第一击 changeAfArea:挪框
          ..ok() // 第二击 afDrive:同点对焦合焦
          ..ok() // 第三击 afDrive:容差内同点(0.02 < 0.05)再对焦
          ..ok() // 第四击 changeAfArea:大位移(0.1 > 0.05)挪框
          ..ok(); // 第五击 afDrive:新位同点对焦
        await controller.touchFocus(0.5, 0.5); // 挪框,无 AF
        expect(transport.count(NikonOperationCode.changeAfArea), 1);
        expect(transport.count(NikonOperationCode.afDrive), 0,
            reason: '挪框不自动 AF');

        await controller.touchFocus(0.5, 0.5); // 同点再点 → AF
        expect(transport.count(NikonOperationCode.changeAfArea), 1,
            reason: '同点不重发 0x9205(挪框纯冗余)');
        expect(transport.count(NikonOperationCode.afDrive), 1);
        expect(controller.afBox!.focused, isTrue, reason: '合焦绿框');

        await controller.touchFocus(0.52, 0.51); // 容差内(0.02/0.01)仍同点
        expect(transport.count(NikonOperationCode.changeAfArea), 1);
        expect(transport.count(NikonOperationCode.afDrive), 2);

        await controller.touchFocus(0.6, 0.5); // 大位移 → 挪框
        expect(transport.count(NikonOperationCode.changeAfArea), 2);
        expect(transport.count(NikonOperationCode.afDrive), 2,
            reason: '挪框不驱动');
        await controller.touchFocus(0.6, 0.5); // 新位同点 → AF
        expect(transport.count(NikonOperationCode.afDrive), 3);
        expect(controller.error, isNull);
      });

      test('同点对焦抢占滚轮(端点作废);挪框不抢占(端点/余量照旧)', () async {
        await startLiveView();
        transport.reply(NikonResponseCode.mfDriveStepEnd);
        await controller.mfDriveStep(towardNear: true);
        expect(controller.mfNearEnd, isTrue);

        // 挪框(不同点):镜头不动,端点态保留(旧口径经 touchFocus 抢占
        // 已随「挪框不自动 AF」一并撤除)。
        transport.ok(); // changeAfArea
        await controller.touchFocus(0.2, 0.8);
        expect(controller.mfNearEnd, isTrue, reason: '挪框不动镜,端点仍有效');

        // 同点再点 = AF:抢占,端点作废(nico clearMfLimits 同款)。
        transport.ok(); // afDrive
        await controller.touchFocus(0.2, 0.8);
        expect(controller.mfNearEnd, isFalse, reason: 'AF 移焦后近端旗作废');
      });

      test('0x90C1 忙(0x2019)→ 同款宽限内逐拍退避静默续发', () async {
        await startLiveView();
        transport.ok(); // 第一击挪框
        await controller.touchFocus(0.5, 0.5);
        // 滚轮驱动在途(模拟):同点再点,AF 连吃四连忙后第 5 拍成功。
        for (var i = 0; i < 4; i++) {
          transport.reply(PtpResponseCode.deviceBusy);
        }
        transport.ok(); // afDrive 第 5 拍成功
        final f = controller.touchFocus(0.5, 0.5);
        await pumpEventQueue();
        for (var i = 0; i < 4; i++) {
          delay.release(); // 第 1..4 次退避
          await pumpEventQueue();
        }
        await f;
        expect(transport.count(NikonOperationCode.afDrive), 5);
        expect(controller.afBox!.focused, isTrue, reason: '合焦绿框');
        expect(controller.error, isNull);
      });

      test('未开取景点按 → 静默忽略,零流量', () async {
        await controller.touchFocus(0.5, 0.5);
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.changeAfArea),
            isEmpty);
        expect(controller.error, isNull);
      });

      test('取景中但帧无 SOF(尺寸未知)→ 提示且不发对焦', () async {
        transport
          ..ok() // 0x9201
          ..ok(data: Uint8List.fromList([1, 2, 3])); // 非 JPEG 帧
        await controller.toggleLiveView();
        await pumpEventQueue();
        expect(controller.frameSize.value, isNull);
        await controller.touchFocus(0.5, 0.5);
        expect(controller.error?.key, 'remote.errNoFrameFocus');
        expect(transport.count(NikonOperationCode.changeAfArea), 0);
      });

      test('对焦按钮:0x90C1 成功;0xA002 未合焦转友好提示;框色随判'
          '(2026-10-12 两色制:未合焦红/合焦绿)', () async {
        await startLiveView();
        transport.ok(); // afDrive 成功
        await controller.afDriveNow();
        expect(controller.error, isNull);
        expect(controller.focusing, isFalse);
        expect(controller.afBox, isNull, reason: '按钮路径无点位,不造框');

        transport.reply(NikonResponseCode.outOfFocus);
        await controller.afDriveNow();
        expect(controller.error?.key, 'remote.errAfFail');
        expect(controller.error?.args?['e'], 'remote.hintOutOfFocus');
        expect(controller.focusing, isFalse);

        // 框色随判:挪框后框回未定红;同点再点对焦,0xA002 → false(红),
        // 合焦 → true(绿)
        transport.ok(); // changeAfArea(挪框)
        await controller.touchFocus(0.5, 0.25);
        expect(controller.afBox!.focused, isNull, reason: '未对焦:未定红');
        transport.reply(NikonResponseCode.outOfFocus); // 同点 AF 未合焦
        await controller.touchFocus(0.5, 0.25);
        expect(controller.afBox!.focused, isFalse, reason: '未合焦红框');
        transport
          ..ok() // changeAfArea(挪框到新位)
          ..ok(); // 同点 AF 合焦
        await controller.touchFocus(0.7, 0.25);
        await controller.touchFocus(0.7, 0.25);
        expect(controller.afBox!.focused, isTrue, reason: '合焦绿框');
      });

      test('对焦按钮:未开取景 → 提示不发(0xA00B notLiveView 应答形态)',
          () async {
        await controller.afDriveNow();
        expect(controller.error?.key, 'remote.errViewfinderOff');
        expect(
            transport.requests
                .where((r) => r.opcode == NikonOperationCode.afDrive),
            isEmpty);
      });

      test('对焦框:停取景即清', () async {
        await startLiveView();
        transport.ok(); // changeAfArea(挪框)
        await controller.touchFocus(0.5, 0.5);
        expect(controller.afBox, isNotNull);
        transport.ok(); // 0x9202
        await controller.toggleLiveView(); // 关取景
        await pumpEventQueue();
        expect(controller.afBox, isNull);
      });

      test('机身对焦模式 MF(0xD061=3 固定/4 选择,全方言两态同拦)→ '
          '触控对焦/AF 钮/MF 步进全拦,提示且零流量', () async {
        await startLiveView();
        for (final mf in kStillFocusModeMfValues) {
          controller.paramProps[PtpDevicePropCode.stillFocusMode] =
              PropState(value: mf);
          await controller.touchFocus(0.5, 0.5);
          await controller.afDriveNow();
          await controller.mfDriveStep(towardNear: true);
          expect(transport.count(NikonOperationCode.changeAfArea), 0,
              reason: 'MF=$mf 触控对焦拦');
          expect(transport.count(NikonOperationCode.afDrive), 0,
              reason: 'MF=$mf AF 钮拦');
          expect(transport.count(NikonOperationCode.mfDrive), 0,
              reason: 'MF=$mf 步进拦');
          expect(controller.notice?.key, 'remote.errMfMode', reason: 'MF=$mf 提示');
          expect(controller.error, isNull, reason: '门闩是状态说明不是错误');
          expect(controller.afBox, isNull, reason: '对焦框不上屏');
        }
      });

      test('机身对焦模式 MF → 拉焦轮拖动丢弃,切回 AF 后无陈旧爆发', () async {
        await startLiveView();
        controller.paramProps[PtpDevicePropCode.stillFocusMode] =
            const PropState(value: 4); // MF(选择,Zf 域内值)
        controller.focusDialDrag(48); // 攒了两步的量:MF 下全部丢弃
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 0);

        // 切回 AF-S(等价 0x4006 定向刷新落值):解锁后新拖动照常驱动,
        // 锁定期余量不爆发(恰一步 = 恰一条 0x9204)。
        controller.paramProps[PtpDevicePropCode.stillFocusMode] =
            const PropState(value: 0);
        transport
          ..ok() // 0x9204 激活
          ..ok(); // 0x90C8 就绪探:完成
        controller.focusDialDrag(24);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 1);
      });

      test('MF 端点方向归因(0xA00C):步进路径近/远各归因,提示随向',
          () async {
        await startLiveView();
        transport.reply(NikonResponseCode.mfDriveStepEnd); // 向近 0x9204 → 0xA00C
        await controller.mfDriveStep(towardNear: true);
        expect(controller.mfNearEnd, isTrue, reason: '向近步进撞尽头 → 近端已到');
        expect(controller.mfFarEnd, isFalse);
        expect(controller.notice?.key, 'remote.focusNearEnd');

        transport.reply(NikonResponseCode.mfDriveStepEnd); // 向远 → 0xA00C
        await controller.mfDriveStep(towardNear: false);
        expect(controller.mfFarEnd, isTrue, reason: '向远步进撞尽头 → 远端已到');
        expect(controller.mfNearEnd, isFalse, reason: '镜头不可能同时顶两端');
        expect(controller.notice?.key, 'remote.focusFarEnd');
      });

      test('MF 端点:0xA00E 步进过小不动旗(提示保留);反向请求即解锁',
          () async {
        await startLiveView();
        transport.reply(NikonResponseCode.mfDriveStepEnd);
        await controller.mfDriveStep(towardNear: true);
        expect(controller.mfNearEnd, isTrue);

        // 同向再步进撞 0xA00E(步进过小,镜头未动):提示保留、旗不动。
        transport.reply(NikonResponseCode.mfDriveStepInsufficiency);
        await controller.mfDriveStep(towardNear: true);
        expect(controller.notice?.key, 'remote.stepTooSmall');
        expect(controller.mfNearEnd, isTrue, reason: '镜头未动,近端旗保留');

        // 反向(向远)请求:近端旗在请求沿作废;0xA00E 不置远端旗。
        transport.reply(NikonResponseCode.mfDriveStepInsufficiency);
        await controller.mfDriveStep(towardNear: false);
        expect(controller.mfNearEnd, isFalse, reason: '反向请求即解锁近端');
        expect(controller.mfFarEnd, isFalse, reason: '0xA00E 镜头未动,不置远端旗');
      });

      test('拉焦轮端点锁:锁向静默不发 0x9204,反向拖一步即解锁续发',
          () async {
        await startLiveView();
        // 首步向近撞尽头(0xA00C)→ 近端锁定。
        transport.reply(NikonResponseCode.mfDriveStepEnd);
        controller.focusDialDrag(24);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 1);
        expect(controller.mfNearEnd, isTrue);

        // 锁定方向继续拖:静默丢增量(反向余量保留),零新流量。
        controller.focusDialDrag(48);
        controller.focusDialDrag(30);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 1,
            reason: '近端已锁:向近增量静默丢弃');

        // 反向(向远)拖:一步即解锁 + 续发照常。
        transport
          ..ok() // 向远 0x9204 激活
          ..ok(); // 0x90C8 就绪探:完成
        controller.focusDialDrag(-24);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 2);
        expect(controller.mfNearEnd, isFalse, reason: '反向请求即解锁');
        final far = transport.requests
            .lastWhere((r) => r.opcode == NikonOperationCode.mfDrive);
        expect(far.params, [2, 300], reason: '向远一步 300 脉冲(真机可见量)');

        // 解锁后向近拖动恢复发送;驱动成功双清端点态。
        transport
          ..ok() // 0x9204 激活
          ..ok(); // 0x90C8 就绪探
        controller.focusDialDrag(24);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 3);
        expect(controller.mfNearEnd, isFalse);
      });

      test('端点锁与滚轮余量:步进路径落锁清滚轮陈旧余量(防反向拖被抵)',
          () async {
        await startLiveView();
        controller.focusDialDrag(20); // 不足一步:攒近向余量
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 0);

        transport.reply(NikonResponseCode.mfDriveStepEnd);
        await controller.mfDriveStep(towardNear: true); // 步进路径落锁
        expect(controller.mfNearEnd, isTrue);

        // 陈旧 +20 近向余量已被落锁清空:向远恰一步(-24)即发(1 条步进
        // + 1 条向远),不被抵成「不足一步」。
        transport
          ..ok() // 向远 0x9204 激活
          ..ok(); // 0x90C8 就绪探:完成
        controller.focusDialDrag(-24);
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 2,
            reason: '步进 1 条 + 向远 1 条(陈旧余量未抵消反向一步)');
        final far = transport.requests
            .lastWhere((r) => r.opcode == NikonOperationCode.mfDrive);
        expect(far.params, [2, 300]);
      });

      test('拉焦轮拒答重排队:激活即忙 → 原量归还退避续发,不横幅不清账',
          () async {
        await startLiveView();
        transport.reply(PtpResponseCode.deviceBusy); // 激活即忙(瞬时 AF 收敛)
        controller.focusDialDrag(48); // 两步量 = 600 脉冲
        await pumpEventQueue();
        expect(transport.count(NikonOperationCode.mfDrive), 1);
        expect(controller.notice, isNull, reason: '瞬时拒答静默不提示');
        expect(controller.error, isNull);

        // 退避到点续发:原脉冲量归还不折损;就绪探完成。
        transport
          ..ok() // 续发激活
          ..ok(); // 0x90C8 就绪探:完成
        delay.release();
        await pumpEventQueue();
        final drives = transport.requests
            .where((r) => r.opcode == NikonOperationCode.mfDrive)
            .toList();
        expect(drives, hasLength(2), reason: '拒答不弃单,退避后续发');
        expect(drives.first.params, [1, 600]);
        expect(drives.last.params, [1, 600], reason: '原量归还重发');
        expect(controller.notice, isNull);
      });

      test('拉焦轮连续拒答:宽限墙钟内逐拍退避静默重试不弃单', () async {
        await startLiveView();
        // 四连拒答(退避门逐拍放行):宽限(4s 墙钟)内一律静默续发,
        // 余量保留;超宽限暂停沿走 DateTime 真钟,桩测不造假钟不覆盖。
        transport
          ..reply(PtpResponseCode.deviceBusy)
          ..reply(PtpResponseCode.deviceBusy)
          ..reply(PtpResponseCode.deviceBusy)
          ..reply(PtpResponseCode.deviceBusy);
        controller.focusDialDrag(24);
        await pumpEventQueue();
        for (var i = 0; i < 3; i++) {
          delay.release();
          await pumpEventQueue();
        }
        expect(transport.count(NikonOperationCode.mfDrive), 4,
            reason: '宽限内退避重试不弃单');
        expect(controller.notice, isNull, reason: '宽限内不出提示');
        expect(controller.error, isNull);
      });

      test('刻度鼓净脉冲:滚轮派发即入账,按钮按结果入账,重置归零,'
          'AF 抢占不回卷', () async {
        await startLiveView();

        // 滚轮:向近一步撞尽头(0xA00C)——派发即 +300,驱动结果不回卷。
        transport.reply(NikonResponseCode.mfDriveStepEnd);
        controller.focusDialDrag(24);
        await pumpEventQueue();
        expect(controller.dialNetPulses.value, 300, reason: '派发即入账(乐观跟手)');
        expect(controller.mfNearEnd, isTrue);

        // 滚轮反向一步完成:300 - 300 = 0(端点锁内的同向拖动不派发不入账)。
        transport
          ..ok() // 0x9204 激活
          ..ok(); // 0x90C8 就绪探:完成
        controller.focusDialDrag(-24);
        await pumpEventQueue();
        expect(controller.dialNetPulses.value, 0, reason: '向远一步等量对冲');

        // 按钮路径:完成入账;0xA00E 步进过小(镜头未动)不入账。
        transport
          ..ok()
          ..ok();
        await controller.mfDriveStep(towardNear: true);
        expect(controller.dialNetPulses.value, 300, reason: '按钮完成入账');
        transport.reply(NikonResponseCode.mfDriveStepInsufficiency);
        await controller.mfDriveStep(towardNear: true);
        expect(controller.dialNetPulses.value, 300, reason: '步进过小镜头未动不入账');

        // 按钮拒答(弃单)不入账。
        transport.reply(PtpResponseCode.deviceBusy);
        await controller.mfDriveStep(towardNear: false);
        expect(controller.dialNetPulses.value, 300, reason: '拒答弃单不入账');

        // AF 移焦抢占(同点再点对焦):鼓面不回卷(避免视觉跳变;镜头
        // 新位置不回推账本);挪框一击同样不动鼓面账。
        transport
          ..ok() // changeAfArea(挪框)
          ..ok(); // afDrive(同点对焦)
        await controller.touchFocus(0.5, 0.5);
        await controller.touchFocus(0.5, 0.5);
        await pumpEventQueue();
        expect(controller.dialNetPulses.value, 300, reason: 'AF 抢占不回卷鼓面');

        // 重置(轮子开关重开)归零。
        controller.resetFocusDial();
        expect(controller.dialNetPulses.value, 0);
      });

      test('0xD061 值未知(desc 拒答未读到)→ 不锁,触控对焦照常', () async {
        await startLiveView();
        // paramProps 无 stillFocusMode 条目 = 值未知(fail-open,不把可用
        // 控制锁死)。
        transport
          ..ok() // changeAfArea(挪框)
          ..ok(); // afDrive(同点对焦)
        await controller.touchFocus(0.5, 0.5);
        expect(transport.count(NikonOperationCode.changeAfArea), 1);
        expect(transport.count(NikonOperationCode.afDrive), 0,
            reason: '挪框不自动 AF(值未知不锁,照常发 0x9205)');
        await controller.touchFocus(0.5, 0.5); // 同点再点 → AF
        expect(transport.count(NikonOperationCode.afDrive), 1);
        expect(controller.notice, isNull);
      });
    });

    test('AE 轮换轮询:取景运行期间按节拍刷三要素,停取景即停', () async {
      final aeGates = Queue<Completer<void>>();
      final aeController = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: _parkedDelay,
        aeDelay: (_) {
          final c = Completer<void>();
          aeGates.add(c);
          return c.future;
        },
      );
      addTearDown(aeController.dispose);
      transport
        ..ok() // 0x9201
        ..ok(data: _fakeFrame()); // 首帧
      await aeController.toggleLiveView();
      await pumpEventQueue();
      expect(aeController.liveViewActive, isTrue);

      // 第 1 拍:三要素全刷(机身重算 → 快门 1/50、ISO 400;快门/ISO 走
      // 厂商读码路由:0xD100 打包裸值 / 0xD0B5 有效 ISO)
      transport
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.fNumber, PtpDataType.uint16, 280))
        ..ok(data: _u32Bytes(1 << 16 | 50)) // 0xD100:1/50s 打包
        ..ok(data: _propDescDataset(
            PtpDevicePropCode.exposureIndex, PtpDataType.uint16, 400))
        ..ok(data: _u32Bytes(400)); // 0xD0B5
      aeGates.removeFirst().complete();
      await pumpEventQueue();
      expect(aeController.exposure?.iso, 400);
      expect(aeController.exposure?.shutterRaw, 1 << 16 | 50);

      // 停取景 → 轮询停:在途节拍放行也不得再刷(脚本未预置应答,
      // 若错误刷新会以脚本耗尽 StateError 炸出 —— Error 不被 on Exception 捕)。
      transport.ok(); // 0x9202
      await aeController.toggleLiveView();
      await pumpEventQueue();
      expect(aeController.liveViewActive, isFalse);
      aeGates.removeFirst().complete();
      await pumpEventQueue();
      expect(aeController.exposure?.iso, 400, reason: '停取景后不得再刷');
    });
}
