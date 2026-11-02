part of 'remote_page_test.dart';

/// 拍摄页交互收口:定时/手动 B 门、录制中离页确认、取景页常亮。
void _interactionGroups() {
  testWidgets(
      '定时 B 门两段倒计时:延时段「延时」小标芯色不变 / 曝光段红芯'
      '白字「曝光」小标(2026-10-17 用户实测两段裸数字连跑,分不清'
      '「在等」还是「在拍」)', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = FakeConnection();
    // 与 _directRemoteController 同构,唯控制器 delay 用真定时器:自拍/
    // 曝光两段秒针要能被测试假时钟推进(引擎/AE 仍驻停不抢脚本)。
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: Future<void>.delayed,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    transport
      ..ok() // 0x9207(延时段到点 → 开门)
      ..ok(); // 0x920C(曝光段到点 → 自动收门)
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    controller.paramProps[PtpDevicePropCode.exposureTime] =
        const PropState(value: 0xFFFFFFFF);
    controller.setSelfTimer(2);
    final press = controller.capturePressed();
    await tester.pump(); // 按下微任务落定:进延时段
    expect(controller.selfTimerCountdown, 2);
    expect(find.text('延时'), findsOneWidget);
    expect(find.text('曝光'), findsNothing);
    final live = LiveDesign.of(tester.element(find.text('延时')));
    expect(tester.widget<Text>(find.text('延时')).style?.color, live.onAccent,
        reason: '延时段芯色不变,前景 = onAccent');

    await tester.pump(const Duration(seconds: 1));
    expect(controller.selfTimerCountdown, 1);
    await tester.pump(const Duration(seconds: 1)); // 到点开门 → 曝光段
    await tester.pump();
    expect(controller.selfTimerCountdown, isNull);
    expect(controller.bulbExposureCountdown, 2);
    expect(find.text('曝光'), findsOneWidget);
    expect(find.text('延时'), findsNothing);
    expect(tester.widget<Text>(find.text('曝光')).style?.color, Colors.white,
        reason: '曝光段红芯白字(录像 REC 同语义)');

    await tester.pump(const Duration(seconds: 1));
    expect(controller.bulbExposureCountdown, 1);
    await tester.pump(const Duration(seconds: 1)); // 到点自动收门
    await press;
    expect(controller.bulbExposureCountdown, isNull);
    expect(controller.selfTimerCountdown, isNull);
    expect(
        transport.requests.where(
            (r) => r.opcode == NikonOperationCode.initiateCaptureRecInMedia),
        hasLength(1));
    expect(
        transport.requests
            .where((r) => r.opcode == NikonOperationCode.terminateCapture),
        hasLength(1));
  });

  testWidgets('B 门按住后指针取消:立即收门,不把相机留在开曝光状态', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = FakeConnection();
    // delay 用真定时器:收门后开门等待环活到下一拍退出,测试可排水。
    final controller = RemoteController(
        session: PtpSession(transport: transport),
        connection: conn,
        engine: LiveViewEngine(
            session: PtpSession(transport: transport), delay: _parkedDelay),
        delay: Future<void>.delayed,
        aeDelay: _parkedDelay);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();

    controller.paramProps[PtpDevicePropCode.exposureTime] =
        const PropState(value: 0xFFFFFFFF); // Bulb 哨兵:按住 = 开曝光
    transport
      ..ok() // 0x9207 开门
      ..ok(); // 0x920C 收门
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(CaptureShutterButton)));
    await tester.pump(const Duration(milliseconds: 150)); // onTapDown 落定
    expect(transport.count(NikonOperationCode.initiateCaptureRecInMedia), 1,
        reason: '按下已开门');
    expect(controller.shutterHoldActive, isTrue);

    // 手指滑出按钮再抬起:TapGestureRecognizer 走 onTapCancel,
    // 不走 onTapUp —— 这条沿必须同样收门。
    await gesture.moveBy(const Offset(0, 200));
    await gesture.up();
    await tester.pump();
    expect(transport.count(NikonOperationCode.terminateCapture), 1,
        reason: '取消沿收门');
    expect(controller.shutterHoldActive, isFalse);
    await tester.pump(const Duration(seconds: 1)); // 开门等待环退出
    await tester.pumpAndSettle();
  });

  testWidgets('录制中返回:先确认,「停止并退出」发 0x920B 后回根页', (tester) async {
    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    transport.ok(); // 0x920B 停录

    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    RemotePage(controller: controller))),
                        child: const Text('根页')))))));
    await tester.tap(find.text('根页'));
    await tester.pumpAndSettle();

    transport.eventCtrl.add(const PtpEvent(
        code: NikonEventCode.movieRecordStarted, transactionId: 0xFFFFFFFF));
    await tester.pumpAndSettle();
    expect(controller.recording, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('拍摄仍在进行'), findsOneWidget, reason: '不静默退页');
    expect(find.text('停止并退出'), findsOneWidget);

    await tester.tap(find.text('停止并退出'));
    await tester.pumpAndSettle();
    expect(controller.recording, isFalse);
    expect(transport.count(NikonOperationCode.endMovieRec), 1,
        reason: '停止后才退页');
    expect(find.text('根页'), findsOneWidget, reason: '已退回根页');
  });

  testWidgets('取景页常亮:进页开、离页还系统默认', (tester) async {
    const channel = MethodChannel('zpill/bg');
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'setScreenAwake') {
        calls.add((call.arguments as Map<Object?, Object?>)['enabled'] == true);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    _portrait(tester);
    final transport = _ScriptTransport();
    final conn = FakeConnection();
    final controller = _directRemoteController(transport, conn: conn);
    addTearDown(controller.dispose);
    _scriptAutoStart(transport);
    await tester
        .pumpWidget(MaterialApp(home: RemotePage(controller: controller)));
    await tester.pumpAndSettle();
    expect(calls, contains(true), reason: '取景页持有屏幕常亮');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.last, isFalse, reason: '离页还系统默认休眠');
  });
}
