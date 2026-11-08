part of 'ptp_session.dart';

/// 0x9434 全卡元数据的单笔超时(覆盖传输层缺省 15s)。
///
/// 相机生成整卡索引的耗时随卡内容增长;Zf/HarmonyOS USB 真机 2026-11-04
/// 实测 15s 内零字节,缺省窗会把「相机还在算」误判成链路死亡。45s 是
/// 生成索引的宽限,失败后由仓库层标记会话降级、改走逐张评级补读,
/// 不再反复用这一笔事务拖死链路。
const Duration kObjectsMetaDataTimeout = Duration(seconds: 45);

/// 遥控域:曝光参数 / Live View / 快门释放 / 属性族(文件原分节注释)。
mixin _RemoteOps on _SessionCore {
  /// 0x9523 UpdateLocation:41B gatt GEO 载荷(data-out)。
  ///
  /// Zf 2026-11-08 真机:Wi-Fi PTP 接受 gatt/percent-minute 布局并写入
  /// 后续照片 EXIF;USB 同码 data-out 被 STALL 且无响应 —— 调用方只在
  /// 无线链路(PTP-IP)上直发,USB 不调。
  Future<void> updateLocation(Uint8List payload) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.updateLocation,
          dataOut: payload,
        )));
    _ensureOk(result, NikonOperationCode.updateLocation);
  }

  /// MfDrive 就绪轮询拍数/间隔(facade 注入,测试收窄归零免真钟等待)。
  int get mfReadyPolls;
  Duration get mfReadyPollInterval;

  /// GetDevicePropValue(0x1015):当前值。响应是裸值数据集,解码类型
  /// 查标准表(见 [PtpDevicePropValue.parse]);方言偏离时改走
  /// [getDevicePropDesc] 拿自描述类型(待真机核对)。
  ///
  /// **扩展属性码(> 0xFFFF,0x0001_xxxx)自动改走 Gen-3 Ex 读**
  /// (0x943B,OpenZCine 实测口径:2 字节码必须走标准 op,混用会拒)。
  Future<PtpDevicePropValue> getDevicePropValue(int propCode) async {
    final op = propCode > 0xFFFF
        ? NikonOperationCode.getDevicePropValueEx
        : PtpOperationCode.getDevicePropValue;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [propCode],
        )));
    _ensureOk(result, op);
    return PtpDevicePropValue.parse(propCode, result.data ?? Uint8List(0));
  }

  /// GetDevicePropDesc(0x1014):属性全描述(类型/可写性/枚举域/默认值),
  /// 数据集自描述类型,是裸值解码的对照组。扩展属性码(> 0xFFFF)自动
  /// 改走 Gen-3 Ex desc(0x943A,同 [getDevicePropValue] 路由口径;
  /// 2026-10-12 USB 探针实证:0x0001D001 色调/0x0001D005-06 主体检测
  /// 全应答,FORM 布局与标准 desc 同构 —— 色调/主体检测从此吃相机
  /// FORM 而非 pickValues 直供)。
  Future<PtpDevicePropDesc> getDevicePropDesc(int propCode) async {
    final op = propCode > 0xFFFF
        ? NikonOperationCode.getDevicePropDescEx
        : PtpOperationCode.getDevicePropDesc;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [propCode],
        )));
    _ensureOk(result, op);
    return PtpDevicePropDesc.parse(result.data ?? Uint8List(0),
        expectedCode: propCode);
  }

  /// SetDevicePropValue(0x1016,数据入相)。门禁 [PtpSession.kSetPropEnabled]。
  /// 扩展属性码(> 0xFFFF)自动改走 Gen-3 Ex 写(0x943C,同
  /// [getDevicePropValue] 的路由口径)。
  Future<void> setDevicePropValue(PtpDevicePropValue value) async {
    if (!PtpSession.kSetPropEnabled) {
      throw UnsupportedError(
          'SetDevicePropValue 已被总闸关断(kSetPropEnabled=false,紧急关断)');
    }
    final op = value.code > 0xFFFF
        ? NikonOperationCode.setDevicePropValueEx
        : PtpOperationCode.setDevicePropValue;
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: op,
          params: [value.code],
          dataOut: value.encode(),
        )));
    _ensureOk(result, op);
  }

  /// SetObjectProtection(0x1012,官方 §6.2.1.14):对象保护标记。
  /// 参数 [句柄, 0x0000 不保护 / 0x0001 只读]。目录(Association)/
  /// SDRAM 对象会被拒(Invalid_Object_Handle),卡写保护回 Store_Read_Only。
  Future<void> setObjectProtection(int objectHandle,
      {required bool protect}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.setObjectProtection,
          params: [objectHandle, protect ? 0x0001 : 0x0000],
        )));
    _ensureOk(result, PtpOperationCode.setObjectProtection);
  }

  /// GetVendorCodes(0x9439,官方 §6.2.2.1):查询相机支持的厂商码全表
  /// —— [deviceProps] = false 拿厂商操作码表(param 0x09),true 拿厂商
  /// 属性码表(param 0x0D)。应答 = u32 元素数 + N×u32 码(4 字节扩展码
  /// 全量,含 0x0001_xxxx 形态)。**这是自录厂商码表的正规通道**,免
  /// 逐码盲试;不在表内的码不代表不应答(STA 9-op 小表同理)。
  Future<List<int>> getVendorCodes({required bool deviceProps}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getVendorCodes,
          params: [deviceProps ? 0x0D : 0x09],
        )));
    _ensureOk(result, NikonOperationCode.getVendorCodes);
    final data = result.data;
    if (data == null || data.length < 4) return const [];
    final bd = ByteData.sublistView(data);
    final count = bd.getUint32(0, Endian.little);
    final codes = <int>[];
    for (var i = 0; i < count && 4 + i * 4 + 4 <= data.length; i++) {
      codes.add(bd.getUint32(4 + i * 4, Endian.little));
    }
    return codes;
  }

  /// 4 字节扩展操作码包装(官方 §6.2.2.2-4):以 0x9440/0x9441/0x9442
  /// 执行 0x0001_xxxx 形态的命令 —— P1 = 扩展码,P2-5 透传命令参数
  /// (至多 4 个;带数据相的命令不能走 [extendedOperationNone])。
  /// 现有 Ex 属性 ops(0x943A-C)之外的第二条官方扩展通道。
  Future<PtpResult> extendedOperationNone(int extOp,
      {List<int> params = const []}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationDataNone,
          params: [extOp, ...params],
        )));
    _ensureOk(result, NikonOperationCode.operationDataNone);
    return result;
  }

  /// 4 字节扩展操作的读数据相版(0x9441,应答数据在 result.data)。
  Future<PtpResult> extendedOperationReceive(int extOp,
      {List<int> params = const []}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationReceiveData,
          params: [extOp, ...params],
        )));
    _ensureOk(result, NikonOperationCode.operationReceiveData);
    return result;
  }

  /// 4 字节扩展操作的写数据相版(0x9442,dataOut 发给相机)。
  Future<PtpResult> extendedOperationSend(int extOp,
      {List<int> params = const [], Uint8List? data}) async {
    assert(params.length <= 4, '包装 op 至多透传 4 个命令参数');
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.operationSendData,
          params: [extOp, ...params],
          dataOut: data ?? Uint8List(0),
        )));
    _ensureOk(result, NikonOperationCode.operationSendData);
    return result;
  }

  /// Nikon GetPicCtrlData(0x90CC):读优化校准(0xD200)槽位详情里的
  /// 注册名。params = [槽位号(即 0xD200 的值), 0=当前值];数据集布局
  /// 按官方指令书 §9.9(ZfUsbMtpE_02)—— BasePictureControl 2 字节 +
  /// RegistrationName 20 字节(ASCII 19 + NUL),名字在 [2..22)。
  /// (2026-10-26 用户真机反馈「自定义/云组名字少开头一个字母」根因:
  /// 旧码按 digiCamControl 口径读 [3..23),恰好吞掉首字母 —— 其 3 字节
  /// 头是旧机型布局,Zf 是 2 字节 BasePictureControl。)
  /// 用于自定义(201-206,Zf FORM 实测 6 槽)/云下载(301-309)槽位的
  /// 真名显示(静态表只有「自定义 N」「云 N」占位);数据不足 22 字节
  /// 或名字空白返回 null,上层回落静态标签。
  Future<String?> getPictureControlName(int slot) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getPictCtrlData,
          params: [slot, 0],
        )));
    _ensureOk(result, NikonOperationCode.getPictCtrlData);
    final data = result.data;
    if (data == null || data.length < 22) return null;
    final nameCodes = <int>[];
    for (var i = 2; i < 22; i++) {
      final b = data[i];
      if (b == 0) break;
      if (b >= 0x20 && b < 0x7F) nameCodes.add(b);
    }
    final name = String.fromCharCodes(nameCodes).trim();
    return name.isEmpty ? null : name;
  }

  /// 连接后切「应用模式」(Z 系真机口径,OpenZCine 实测:不切则相机对
  /// 遥控写回 0x200F AccessDenied)。链路对齐 OpenZCine 连接脚本:
  /// ① 0x9435 ChangeApplicationMode p1=1(无线/二代+直通);②
  /// [remoteLatch](连接流两路同款,USB/无线)→ **0x90C2 ChangeCameraMode(1)
  /// 进 remote 模式**。2026-10-07 归因梯(macOS-IC 真机,即 iPhone 代理
  /// 链)定案:0x9435 在 IC 人设下**回 OK 但是假钥匙** —— 0x9201 仍被
  /// 0xA004 拒;唯一实证解锁 = 0x90C2(1)(接受即 0x9201 通、取到 84KB
  /// 帧;机身 remote + 取景运行 = 及时取景)。2026-10-26 USB 探针补点:
  /// 裸会话(macOS 直连,无 IC 代理)0x9435(1) 回 **0x200F** —— IC 人设
  /// OK 假钥匙 / 裸 USB 0x200F 拒,两态同证真闩唯 0x90C2(1)。
  /// **无线/AP 同病(2026-10-15
  /// 真机)**:AP 进拍摄取景/对焦全坏 —— 0x9435 在无线上同样回 OK 假
  /// 钥匙,旧无线流只发 0x9435 即返回,0x90C2 全程没拉过;故连接流
  /// **无论传输介质、无论 0x9435 成败都直取 remote 模式**(OpenZCine
  /// 「0x9435 失败才兜底 0x90C2」的分支在人设下永远走不到);0x90C2
  /// 未成而 0x9435 已 OK 仍按旧语义算成;③ 双双未成 → 回退写
  /// ApplicationMode 属性 0xD1F0=1(u8,一代 op 缺席口径)。remote 的
  /// 镜像收尾在连接层(CloseSession 前 0x90C2(0)):不退则机身停
  /// 「已连接到计算机」屏(2026-10-07 真机:remote 态跨拔插保持,半按
  /// 快门才退)。
  /// **不写 0xD406 initiator 身份**:OpenZCine 全程不写,而身份写会让
  /// 机身把主机按新身份归类(op 表 119→124 变化)—— 2026-10-07 真机
  /// 复报:写身份 + remote 模式 = 机身停「已连接到计算机」屏不进取景;
  /// 不写 + remote 模式 + 连接即开取景(HomeShell autoLiveViewOnConnect)
  /// = 及时取景。usbfs 主机实证过的身份写只保留在 LiveViewEngine 的
  /// 0xA004 自愈末级(见 [writeInitiatorIdentity])。
  /// **不走 [PtpSession.kSetPropEnabled] 门禁** —— 它是连接模式控制而非拍摄参数
  /// 写,且发生在任何参数面板之前;连双失败也只返回 false 不抛(尽力
  /// 而为,拍照/读参数不依赖它,真机核对)。
  Future<bool> enableAppControl({bool remoteLatch = false}) async {
    var rc = PtpResponseCode.operationNotSupported;
    if (!remoteLatch) {
      try {
        final result = await _serialized(() => transport.execute(PtpRequest(
              opcode: NikonOperationCode.changeApplicationMode,
              params: [1],
            )));
        rc = result.responseCode;
        noteLadder('9435:${_ladderRc(rc)}');
      } on Object {
        // op 缺席/链路类(含脚本耗尽类 StateError):走回退。
        // 尽力而为步骤,on Object 兜底 —— 它失败不得影响连接主流程。
        noteLadder('9435:ERR');
      }
      if (rc == PtpResponseCode.ok) return true;
    } else {
      // 连接流直取 remote 闩:0x9435 是假钥匙(0x9201 仍 0xA004),
      // 且 Zf 固件要 ~5s 才回 —— 它占住会话串行门会把连接后镜头/
      // 存储/电量等概览读取全部堵在后面(2026-11-04 真机)。唯一实证
      // 解锁 = 0x90C2(1),故 remoteLatch 路径不再发 0x9435。
      noteLadder('9435:SKIP');
    }
    if (remoteLatch) {
      // 2026-10-07 归因梯定案(macOS-IC 真机):0x9435 在 IC 人设下回
      // OK 但是假钥匙(0x9201 仍 0xA004),唯一实证解锁 = 0x90C2(1)。
      // 2026-10-15 真机:无线/AP 同病(0x9435 同样 OK 假钥匙)。故连接
      // 流无论介质、无论 0x9435 成败都直取 remote 模式。
      try {
        await changeCameraMode(1);
        noteLadder('90C2:OK');
        // 开闩即还身(2026-10-07 v8/v9 定案):上传优先门是**单向闩**
        // —— 0x90C2(1) 打开后不因 0x90C2(0) 而关(v9 ⑧→⑨→⑩:背靠背
        // 1→0 后 0x9201 照通、帧照流);而 remote **持有态**才是机身停
        // 「已连接到计算机」屏的元凶(拨盘锁定,取景运行也不翻屏)。
        // 1→0 背靠背 = 已连接屏只闪一次往返,机身直回自己的取景屏。
        // 退失败不影响流(仅屏显停留已连接),由 teardown 兜底。
        try {
          await changeCameraMode(0);
          noteLadder('90C2退:OK');
        } on Object {
          noteLadder('90C2退:拒');
        }
        return true;
      } on PtpResponseException catch (e) {
        noteLadder('90C2:${_ladderRc(e.responseCode)}');
      } on Object {
        // 0x90C2 也被拒/链路类:落到 0xD1F0。
        noteLadder('90C2:ERR');
      }
    }
    if (rc == PtpResponseCode.ok) return true; // remote 未成但应用模式已接受
    try {
      final w = ByteWriter()..u8(1);
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: PtpOperationCode.setDevicePropValue,
            params: [PtpDevicePropCode.applicationMode],
            dataOut: w.takeBytes(),
          )));
      noteLadder('D1F0:${_ladderRc(result.responseCode)}');
      return result.responseCode == PtpResponseCode.ok;
    } on Object {
      noteLadder('D1F0:ERR');
      return false;
    }
  }

  /// 写会话发起者身份 0xD406='ZPill'(尽力而为,失败/被拒返 false)。
  ///
  /// Zf USB 实证(2026-10-07 探针):initiator 为出厂/残留 MTP 主机串
  /// ('Windows/… MTPClassDriver')时 0x9201 StartLiveView 被拒 0xA004,
  /// 写任一非 MTP 身份串('ZPill'/'Android Device' 均验)即解锁;
  /// 该值**每次连接弹回出厂**。身份写同时让机身把主机按新身份归类
  /// (op 表 119→124 变化;真机复报:remote 模式下带身份写 = 停
  /// 「已连接到计算机」屏),**且 iOS IC 链上不生效** —— 故连接流
  /// [enableAppControl] 不再写它(OpenZCine 全程不写),只作
  /// LiveViewEngine 0xA004 自愈的**末级**兜底(usbfs 直连主机
  /// 0x90C2 意外失效时的另一把钥匙)。
  /// 载荷 = PTP 字符串(u8 字符数 + UTF-16LE,无终止符),与探针
  /// ptp_str 同款。
  Future<bool> writeInitiatorIdentity() async {
    try {
      final w = ByteWriter()..ptpString('ZPill');
      final result = await _serialized(() => transport.execute(PtpRequest(
            opcode: PtpOperationCode.setDevicePropValue,
            params: [PtpDevicePropCode.sessionInitiatorInfo],
            dataOut: w.takeBytes(),
          )));
      return result.responseCode == PtpResponseCode.ok;
    } on Object {
      return false; // op 不在册/链路类:尽力而为,不拦调用方
    }
  }

  /// Nikon ChangeCameraMode(0x90C2,源 = OpenZCine 全系在册):切换
  /// 「remote / PC-camera」模式。[mode] 1 = remote(**APP 接管控制**:
  /// 机身拨盘锁定,host 写入的会话值仅在持有期保值)。2026-10-07 真机
  /// 定案:USB 上传优先门(0x9201 → 0xA004)的唯一实证钥匙(0x9435
  /// 是假钥匙);remote + 0x9201 取景运行 = 机身及时取景,remote 持有
  /// 而取景停 = 机身停「已连接到计算机」屏(跨拔插保持,0x90C2(0)
  /// 或半按快门才退)。0 = 解除。
  /// 可在释放/AF/清洁中被拒(0xA003),调用方容忍。
  /// 成功即同步 [remoteModeActive]。
  Future<void> changeCameraMode(int mode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeCameraMode,
          params: [mode],
        )));
    _ensureOk(result, NikonOperationCode.changeCameraMode);
    _remoteModeActive = mode == 1;
  }

  /// Nikon StartLiveView(0x9201,候选码,待真机核对)。
  /// 每次开启取景重置 [getLiveViewObject] 的取码回退旗标 —— 会话跨
  /// 连接复用(PtpLinkRouter 换 transport),换接一台支持 0x9428 的
  /// 机身时下一次取景自动重新直试 Ex 码。
  Future<void> startLiveView() async {
    _liveViewFallbackLegacy = false;
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.startLiveView),
        ));
    _ensureOk(result, NikonOperationCode.startLiveView);
  }

  /// Nikon EndLiveView(0x9202,候选码,待真机核对)。
  Future<void> endLiveView() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.endLiveView),
        ));
    _ensureOk(result, NikonOperationCode.endLiveView);
  }

  /// Nikon GetLiveViewImage(0x9203,候选码,待真机核对):取一帧取景图像。
  /// 帧格式未经抓包定案,复用缩略图的 SOI 嗅探剥杂头(防御性兼容
  /// 「头 + JPEG」形态),嗅探不到 SOI 原样返回交上层解码器报错。
  Future<Uint8List> getLiveViewImage() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getLiveViewImage),
        ));
    _ensureOk(result, NikonOperationCode.getLiveViewImage);
    final data = result.data ?? Uint8List(0);
    return _sniffJpegStart(data) ?? data;
  }

  /// 同取帧,但**不剥头**返回原始 LiveViewObject —— display-info 头
  /// 里带相机每帧自报的 AF 框/虚拟水平仪/录制态(见
  /// core/remote/live_view_header.dart),监看层用它解析后再取 JPEG。
  ///
  /// 取码口径(2026-10-07 订正):**先 0x9428 GetLiveViewImageEx** ——
  /// OpenZCine 全系(Gen-1/2/3)取帧只用它,应答必带 display-info 头;
  /// 旧 0x9203 在 Zf 上应答解析不出头(水平仪回落手机/对焦框不出的
  /// 根因)。被拒(不支持/拒绝类,非忙)则记下会话内改走 0x9203 兜底
  /// (本次上抛、下一拍生效);0x2019 忙是正常轮询抖动,不上旗标照常
  /// 上抛给引擎退避。
  Future<Uint8List> getLiveViewObject() async {
    if (_liveViewFallbackLegacy) {
      final result = await _serialized(() => transport.execute(
            const PtpRequest(opcode: NikonOperationCode.getLiveViewImage),
          ));
      _ensureOk(result, NikonOperationCode.getLiveViewImage);
      return result.data ?? Uint8List(0);
    }
    try {
      final result = await _serialized(() => transport.execute(
            const PtpRequest(opcode: NikonOperationCode.getLiveViewImageEx),
          ));
      _ensureOk(result, NikonOperationCode.getLiveViewImageEx);
      return result.data ?? Uint8List(0);
    } on PtpResponseException catch (e) {
      if (e.responseCode == PtpResponseCode.deviceBusy) rethrow;
      _liveViewFallbackLegacy = true; // 下一拍起走 0x9203
      rethrow;
    }
  }

  /// 0x9428 被拒后本会话改走 0x9203(StartLiveView 时重置 —— 会话跨
  /// 连接复用,换接机身后下一次取景自动重新直试 Ex 码)。
  bool _liveViewFallbackLegacy = false;

  /// InitiateCapture(0x100E 标准,params [0,0]):快门释放,落卡存储。
  /// 0x2019 DeviceBusy(半按对焦未就绪等)按异常上抛,上层提示重试。
  Future<void> initiateCapture() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(
              opcode: PtpOperationCode.initiateCapture, params: [0, 0]),
        ));
    _ensureOk(result, PtpOperationCode.initiateCapture);
  }

  /// Nikon InitiateCaptureRecInMedia(0x9207):落卡拍。
  /// 参数 [captureSort, 0x0000] 对齐 OpenZCine initiateStillCapture
  /// (libgphoto2 ptp_nikon_capture2 双参形态):[captureSort] 缺省
  /// 0xFFFFFFFF = 直接释放不动焦点(preserveFocus 形态);0xFFFFFFFE =
  /// 先驱动 AF 再释放(半按-全按);0x0000 为旧实证形(2026-10-05 Zf
  /// 真机通过,但 2026-10-06 应用模式/接管态被 0x201D InvalidParameter
  /// 拒 —— 上层 [RemoteController] 按候选序回退)。参数在 USB/PTP-IP
  /// 容器里都是 u32,哨兵值两条链路均可完整传输。
  Future<void> initiateCaptureRecInMedia({int captureSort = 0xFFFFFFFF}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.initiateCaptureRecInMedia,
          params: [captureSort, 0],
        )));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInMedia);
  }

  /// Nikon TerminateCapture(0x920C,params [0,0]):终止进行中的连拍/
  /// Bulb 曝光,已拍帧保留(OpenZCine terminateStillCapture 同款;运行
  /// 已自行结束时相机会拒绝,调用方容忍)。真机核对。
  Future<void> terminateCapture() async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.terminateCapture,
          params: [0, 0],
        )));
    _ensureOk(result, NikonOperationCode.terminateCapture);
  }

  /// Nikon MfDrive(0x9204):手动对焦步进(相对量,跟焦环语义 ——
  /// 无绝对位置读出)。[towardNear] true = 向近对焦(参数 1)/false
  /// = 向远(参数 2);[pulses] 步进量,钳到 1..32767。
  ///
  /// **激活型命令**(官方 §6.2.5.3 定案):0x9204 的 OK 只代表「已
  /// 开始」,完成态经 0x90C8 DeviceReady 读回 —— OK=完成 / 0x2019=仍
  /// 在驱动(继续等)/ 0xA00C 行程尽头 / 0xA00E 步进过小 / 其余=失败
  /// (OpenZCine「activation + bounded readiness poll」同款)。有界:
  /// 超时乐观按已派出(complete)—— 端点归因靠下一拍自愈,不算失败。
  /// 激活即拒(机身 MF Invalid_Status / AF-F·AF 忙 0x2019 / 参数类)与
  /// 链路异常 → refused;0xA00C/A00E 理论上不走激活路,兼容兜底照旧
  /// 归因(他机身方言)。
  Future<MfDriveOutcome> mfDrive(
      {required bool towardNear, required int pulses}) async {
    final clamped = pulses.clamp(1, 32767);
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.mfDrive,
            params: [towardNear ? 1 : 2, clamped],
          )));
    } on Exception {
      return MfDriveOutcome.refused;
    }
    if (result.responseCode != PtpResponseCode.ok) {
      return switch (result.responseCode) {
        NikonResponseCode.mfDriveStepEnd => MfDriveOutcome.endOfTravel,
        NikonResponseCode.mfDriveStepInsufficiency =>
          MfDriveOutcome.stepTooSmall,
        _ => MfDriveOutcome.refused,
      };
    }
    for (var i = 0; i < mfReadyPolls; i++) {
      // 首探立即:短驱动(百毫秒级)一步到位;其后隔 [mfReadyPollInterval]
      // 再探,间隔外让帧事务照常插队(轮询不锁命令通道)。
      if (i > 0) {
        await Future<void>.delayed(mfReadyPollInterval);
      }
      final PtpResult probe;
      try {
        probe = await _serialized(() => transport.execute(
              const PtpRequest(opcode: NikonOperationCode.deviceReady),
            ));
      } on Exception {
        AppLog.w(AppLog.protocol, '9204 就绪轮询链路异常 → refused');
        return MfDriveOutcome.refused;
      }
      final outcome = switch (probe.responseCode) {
        PtpResponseCode.ok => MfDriveOutcome.complete,
        PtpResponseCode.deviceBusy => null, // 仍在驱动,继续等
        NikonResponseCode.mfDriveStepEnd => MfDriveOutcome.endOfTravel,
        NikonResponseCode.mfDriveStepInsufficiency =>
          MfDriveOutcome.stepTooSmall,
        _ => MfDriveOutcome.refused,
      };
      if (outcome != null) return outcome;
    }
    AppLog.w(AppLog.protocol,
        '9204 就绪轮询超时($mfReadyPolls 拍)→ 乐观 complete');
    return MfDriveOutcome.complete;
  }

  /// Nikon StartMovieRecInCard(0x920A,无参无数据):开始卡上录制
  /// (取景开启为前置;OpenZCine 同款,真机核对)。
  Future<void> startMovieRec() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.startMovieRecInCard,
        )));
    _ensureOk(result, NikonOperationCode.startMovieRecInCard);
  }

  /// Nikon EndMovieRec(0x920B,无参无数据):结束卡上录制。
  Future<void> endMovieRec() async {
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.endMovieRec,
        )));
    _ensureOk(result, NikonOperationCode.endMovieRec);
  }

  /// 相机时钟(0x5011,PTP 日期时间 STR 型 "YYYYMMDDTHHMMSS")。
  /// 读:本地墙钟口径比较(相机值无时区,跨时区携带的机身按本地时间
  /// 对齐是操作者预期 —— OpenZCine CameraClockSync 同款)。null = 读
  /// 失败/畸形。
  Future<DateTime?> getCameraClock() async {
    try {
      final v = await getDevicePropValue(PtpDevicePropCode.dateTime);
      final s = v.value as String?;
      if (s == null || s.length < 14) return null;
      final y = int.tryParse(s.substring(0, 4));
      final mo = int.tryParse(s.substring(4, 6));
      final d = int.tryParse(s.substring(6, 8));
      final h = int.tryParse(s.substring(9, 11));
      final mi = int.tryParse(s.substring(11, 13));
      final sec = int.tryParse(s.substring(13, 15));
      if (y == null ||
          mo == null ||
          d == null ||
          h == null ||
          mi == null ||
          sec == null) {
        return null;
      }
      return DateTime(y, mo, d, h, mi, sec);
    } on Exception {
      return null;
    }
  }

  /// 相机时钟校准:把相机时钟设为手机本地时间([now] 注入供测试)。
  /// OpenZCine 口径:**只在漂移超过阈值时写**(事务延迟 + 线格式 1 秒
  /// 粒度让小修正抖动;5 秒高于任何监看用途又必抓到抽屉里放一年的
  /// 机身),且不await影响连接主流程(尽力而为)。
  Future<void> syncCameraClock(
      {DateTime? now, Duration threshold = const Duration(seconds: 5)}) async {
    final phone = (now ?? DateTime.now());
    final camera = await getCameraClock();
    if (camera == null) return;
    if (phone.difference(camera).abs() < threshold) return;
    final t = phone.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final s = '${t.year}${two(t.month)}${two(t.day)}T'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      await setDevicePropValue(PtpDevicePropValue(
          code: PtpDevicePropCode.dateTime,
          dataType: PtpDataType.string,
          value: s));
    } on Exception {
      // 尽力而为:校时失败不影响连接
    }
  }

  /// Nikon InitiateCaptureRecInSdram(0x90C0):SDRAM 拍摄(无卡拍进
  /// 机身缓存,速传场景的对象随后经 ObjectAddedInSdram 事件流出)。
  /// **必须有 CaptureSort 参数**(2026-10-13 USB 探针:无参 0x2006、
  /// [0,0] 0x201D、0xFFFFFFFF 直释放 0x2001 —— 官方 §6.2.4.2
  /// P1=CaptureSort 同 0x9207;[0,0] 是两码共用的坑)。
  /// [captureSort] 缺省 0xFFFFFFFF。
  Future<void> initiateCaptureRecInSdram({int captureSort = 0xFFFFFFFF}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
        opcode: NikonOperationCode.initiateCaptureRecInSdram,
        params: [captureSort])));
    _ensureOk(result, NikonOperationCode.initiateCaptureRecInSdram);
  }

  /// Nikon ChangeAfArea(0x9205):移动取景对焦区域。
  /// 参数布局按 OpenZCine PTPIPClientSession:两 UINT32 = 帧头 whole-size
  /// 坐标系 x/y(@16/18,如 6048×3400;recentre 发 coordinateWidth/2 实证),
  /// 无数据相。需取景开启(取景结束的机身拒 ChangeAfArea)。
  Future<void> changeAfArea(int x, int y) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeAfArea,
          params: [x, y],
        )));
    _ensureOk(result, NikonOperationCode.changeAfArea);
  }

  /// Nikon AfDrive(0x90C1,候选码,待真机核对):驱动自动对焦(一次
  /// 半按)。需取景开启(0xA00B notLiveView = 未开取景的应答形态);
  /// 未合焦回 0xA002 OutOfFocus,状态不允许回 0xA004。
  Future<void> afDrive() async {
    final result = await _serialized(() => transport
        .execute(const PtpRequest(opcode: NikonOperationCode.afDrive)));
    _ensureOk(result, NikonOperationCode.afDrive);
  }

  /// Nikon AfDriveCancel(0x9206,官方 §6.2.5.2)。**2026-10-17 真机
  /// 定案:生产已无调用方** —— Zf 对 0x90C1 扣住应答直至 AF 结束
  /// (0xA002 未合焦即从该应答带回),AF 期间线路被在途事务占死,
  /// 本操作排队只能到 AF 后空放;对焦钮改零发包如实提示
  /// (remote.focusInProgress)。方法留档备将来「开始即回 OK」两段流
  /// AF 的机身。
  Future<void> afDriveCancel() async {
    final result = await _serialized(() => transport
        .execute(const PtpRequest(opcode: NikonOperationCode.afDriveCancel)));
    _ensureOk(result, NikonOperationCode.afDriveCancel);
  }

  /// Nikon DeviceReady(0x90C8):拍照后的忙等探针。
  /// **忙等码是语义不是错误**(返回 false):0x2019 DeviceBusy(标准);
  /// 0xA200 Bulb_Release_Busy / 0xA201 Silent_Release_Busy(官方
  /// §6.3.2.15/16 定名;§2.8.4 B 门序列步 5 实证 —— B 门曝光进行中
  /// DeviceReady 即回 0xA200,收门/落定等待据此继续等,2026-10-15)。
  /// 其余响应码照常抛 [PtpResponseException],链路级异常自然传播
  /// (调用方据此判死链)。
  Future<bool> deviceReady() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.deviceReady),
        ));
    final rc = result.responseCode;
    if (rc == PtpResponseCode.deviceBusy ||
        rc == NikonResponseCode.bulbReleaseBusy ||
        rc == NikonResponseCode.silentReleaseBusy) {
      return false;
    }
    _ensureOk(result, NikonOperationCode.deviceReady);
    return true;
  }

  // ── 官方指令书候选区接线(2026-10-13 USB 探针批 + §6.2 规格比对)──

  /// GetFhdPicture(0x920F):对象的 FHD 尺寸 JPEG(探针实录 744KB)。
  /// 无 FHD 可取回 0xA00F NoFullHDPresent(由 [_ensureOk] 抛,调用方
  /// 回落 GetThumb)。NEF 预览快路:744KB 对比整档 NEF 数十 MB。
  Future<Uint8List> getFhdPicture(int handle) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(
              opcode: NikonOperationCode.getFhdPicture, params: [handle]),
        ));
    _ensureOk(result, NikonOperationCode.getFhdPicture);
    final data = result.data ?? Uint8List(0);
    // 与 GetThumb 同款宽收:无 SOI 原样返回,交上层解码器报错占位。
    return _sniffJpegStart(data) ?? data;
  }

  /// ChangeAELock(0x9426,官方 §6.2.4.5):AE/AWB 锁开关。
  /// [lock] P1 LockValue(0 释放/1 锁 hold);[type] P2 LockType
  /// (0=AE/1=AWB/2=AE+AWB,2026-10-13 规格书坐标重排定案;探针
  /// (1,2) 锁/(0,2) 解锁双 OK)。**应答 OK ≠ 生效**(官方明说):调用方
  /// 事后读 AELockStatus 0xD105 / AWBLockStatus 0xD12F 确认。WB 非
  /// auto 时 AWB 锁被拒 0x200F、AE+AWB 只生效 AE(官方 Response 表)。
  Future<void> changeAELock({required bool lock, int type = 2}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeAELock,
          params: [lock ? 1 : 0, type],
        )));
    _ensureOk(result, NikonOperationCode.changeAELock);
  }

  /// StartTracking(0x9424,官方 §6.2.6.7):开始主体追踪 / 更新追踪目标。
  /// 参数同 ChangeAfArea(0x9205):whole-size 坐标系 x/y。门控在官方
  /// Access_Denied 条文:照片档 0xD05D 须自动区/追踪档(拒 0x200F),
  /// 无取景 0xA00B;坐标处有识别目标则更新选中并进待命,没有则以该
  /// 坐标起追。追踪态跟 LiveViewObject 帧头(§2.9),不设独立读回。
  Future<void> startTracking(int x, int y) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.startTracking,
          params: [x, y],
        )));
    _ensureOk(result, NikonOperationCode.startTracking);
  }

  /// EndTracking(0x9425):结束主体追踪(无参)。
  Future<void> endTracking() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.endTracking),
        ));
    _ensureOk(result, NikonOperationCode.endTracking);
  }

  /// ClearEvent(0x9461,探针 2026-10-13 OK):清相机事件队列 ——
  /// 重连沿清上一会话残留,防旧事件误触发即拍即览等消费端。
  Future<void> clearEvent() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.clearEvent),
        ));
    _ensureOk(result, NikonOperationCode.clearEvent);
  }

  /// AfAndCaptureRecInSdram(0x90CB,官方 §6.2.4.3 无参):AF 驱动后
  /// 拍摄入 SDRAM(= 0x9207 [0xFFFFFFFE, 0x0001] 的固定形,探针无参
  /// OK)。对象随后按 §2.8.2 流出:ObjectAddedInSdram 0xC101(逐张带
  /// 句柄)→ GetObjectInfo → GetObject/GetPartialObject → 全部取完
  /// 收 CaptureCompleteRecInSdram 0xC102。
  Future<void> afAndCaptureRecInSdram() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.afAndCaptureRecInSdram),
        ));
    _ensureOk(result, NikonOperationCode.afAndCaptureRecInSdram);
  }

  /// ChangeMonitorOff(0x9422,官方 §6.2.2.17):主监听器(机背屏)
  /// 强制关/取消。P1 0 取消强制关闭 / 1 强制关闭。**应答 OK 只代表
  /// 「请求已收到」,完成不保证**;状态读回 MonitorOffStatus 0xD1BA
  /// (u8 只读 0/1)。电池耗尽拒 0x200F、拍摄中拒 0x2019。
  Future<void> changeMonitorOff({required bool off}) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.changeMonitorOff,
          params: [off ? 1 : 0],
        )));
    _ensureOk(result, NikonOperationCode.changeMonitorOff);
  }

  /// SaveCameraSetting(0x9420,官方 §6.2.2.18):设置落非易失区(与
  /// 关机时落盘同动作)。**响应后除 CloseSession 外禁发任何命令**
  /// (官方 Command Outline)—— 调用方须自行遵守,故不接 UI。
  Future<void> saveCameraSetting() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.saveCameraSetting),
        ));
    _ensureOk(result, NikonOperationCode.saveCameraSetting);
  }

  /// GetCameraSettingData(0x946D,官方 §6.2.2.19):读卡 1 上的相机
  /// 设定文件(机身菜单「保存/载入设定」产物)。数据集 = 64B ASCII
  /// 文件名(63 字符 + NUL)+ 文件体;无卡/卡初始化中 Store_Not_Available。
  Future<({String name, Uint8List data})> getCameraSettingData() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getCameraSettingData),
        ));
    _ensureOk(result, NikonOperationCode.getCameraSettingData);
    final data = result.data ?? Uint8List(0);
    var name = '';
    if (data.length >= 64) {
      final end = data.indexWhere((b) => b == 0, 0);
      name =
          String.fromCharCodes(data.sublist(0, end < 0 || end > 63 ? 63 : end));
      return (name: name, data: Uint8List.sublistView(data, 64));
    }
    return (name: name, data: data);
  }

  /// SendCameraSettingData(0x946E,官方 §6.2.2.20):把设定文件写回
  /// 卡 1。**只写卡,不应用到相机**(应用须机身菜单载入)—— 与快照
  /// 逐属性恢复(直接写属性)语义不同,调用方提示语须如实区分。
  Future<void> sendCameraSettingData(String name, Uint8List data) async {
    final bytes = ByteWriter();
    final nameBytes = name.length > 63 ? name.substring(0, 63) : name;
    for (var i = 0; i < 64; i++) {
      bytes.u8(i < nameBytes.length ? nameBytes.codeUnitAt(i) : 0);
    }
    bytes.raw(data);
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.sendCameraSettingData,
          dataOut: bytes.takeBytes(),
        )));
    _ensureOk(result, NikonOperationCode.sendCameraSettingData);
  }

  /// GetObjectPropsSupported(0x9801,官方 §6.2.11.1):相机支持的对象
  /// 属性码表(u32 计数 + N×u16)。
  Future<List<int>> getObjectPropsSupported() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getObjectPropsSupported),
        ));
    _ensureOk(result, NikonOperationCode.getObjectPropsSupported);
    return _parseU16Array(result.data);
  }

  /// GetObjectsMetaData(0x9434,官方 §6.2.3.3):尼康专有批量元数据 ——
  /// 全卡句柄 + ObjectAttribute(**bit0 = Rating 有无、bit1 = Protected**)
  /// + 修改时刻。删除候选(机身垃圾桶)的协议侧不出口(位图不标、
  /// 0xDC8A 读 0),本 op 的属性位与文件层 NCTG/xmp 互为印证通道。
  Future<List<PtpObjectMeta>> getObjectsMetaData() async {
    final raw = await getObjectsMetaDataRaw();
    return parseObjectsMetaData(raw);
  }

  /// 0x9434 裸数据集(诊断取证用:布局有疑,原文先落袋)。
  ///
  /// 超时用 [kObjectsMetaDataTimeout] 覆盖缺省 15s:Zf 在 HarmonyOS USB
  /// 上生成整卡索引可明显超过缺省窗(2026-11-04 真机:15s 零字节 →
  /// 传输层判死 → 重新枚举 → 反复弹 USB 授权)。放宽的是这一笔事务的
  /// 等待上限;仍失败则由仓库层标记会话降级,不再自动重试。
  Future<Uint8List> getObjectsMetaDataRaw() async {
    if (_objectsMetaDataDegraded) {
      // Exception(不是 Error):仓库事件重同步沿只 catch Exception。
      throw Exception('GetObjectsMetaData(0x9434) 本会话已降级');
    }
    final result = await _serialized(() => transport.execute(const PtpRequest(
          opcode: NikonOperationCode.getObjectsMetaData,
          // P1 = 0xFFFFFFFF 全卡;P2 = 0x00000000 全格式(§6.2.3.3 参数表)。
          params: [0xFFFFFFFF, 0x00000000],
          timeout: kObjectsMetaDataTimeout,
        )));
    _ensureOk(result, NikonOperationCode.getObjectsMetaData);
    return result.data ?? Uint8List(0);
  }


  /// GetObjectPropDesc(0x9802,官方 §6.2.11.2):对象属性描述(类型/
  /// 可写性/FORM)。数据集随类型变宽(u16 类型 + u8 GetSet + FORM),
  /// 本轮无消费方,先裸透传,接线时按属性定宽解。
  Future<Uint8List> getObjectPropDesc(int handle, int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getObjectPropDesc,
          params: [handle, propCode],
        )));
    _ensureOk(result, NikonOperationCode.getObjectPropDesc);
    return result.data ?? Uint8List(0);
  }

  /// GetObjectPropValue(0x9803,官方 §6.2.11.3):读对象属性裸值。
  /// 类型自描述不在值内(见 0x9802 Desc),调用方按已知属性定宽解
  /// (如 ProtectionStatus 0x0004 = u16)。
  Future<Uint8List> getObjectPropValue(int handle, int propCode) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getObjectPropValue,
          params: [handle, propCode],
        )));
    _ensureOk(result, NikonOperationCode.getObjectPropValue);
    return result.data ?? Uint8List(0);
  }

  /// SetObjectPropValue(0x9804,官方 §6.2.11.4):写对象属性裸值。
  Future<void> setObjectPropValue(
      int handle, int propCode, Uint8List value) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.setObjectPropValue,
          params: [handle, propCode],
          dataOut: value,
        )));
    _ensureOk(result, NikonOperationCode.setObjectPropValue);
  }

  /// GetObjectPropList(0x9805,官方 §6.2.11.5):对象属性批量读 ——
  /// 一把拿多对象多属性(首屏枚举 1×RTT 替代 N×GetObjectInfo)。
  ///
  /// 参数(官方 §6.2.11.5 Operation Parameter 表,按位序不可跳档):
  /// [handle] P1 ObjectHandle:具体句柄 / 0x00000000 根层直下 /
  /// 0xFFFFFFFF 全部对象;[formatCode] P2 [ObjectFormatCode]:
  /// 0x00000000 = 全部格式;[propCode] P3 ObjectPropCode:具体属性码 /
  /// 0x00000000(按 [groupCode] 组,Zf §6.6 信息组 = 0x00000001)/
  /// 0xFFFFFFFF 全部属性;[groupCode] P4 [ObjectPropGroupCode](仅 P3=
  /// 0x00000000 时生效;给了 [depth] 而未给组码时补 0x00000000 占位);
  /// [depth] P5 [Depth]:null = 省略(仅 P1 指定对象)/ 0x00000000
  /// 指定深度 / 0xFFFFFFFF 整个层级。首屏全量五参形
  /// [0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF] = n-link 生产同款。
  ///
  /// 数据集(官方 §6.2.11.5 数据集表)= u32 NumberOfElements +
  /// N×(u32 ObjectHandle + u16 PropertyCode + u16 Datatype + DTS 值),
  /// **无 GetSet 字节**(那是 0x9802 ObjectPropDesc 的布局;n-link 的
  /// 「无计数前缀连续流」口径与官方表相左,以官方为准 —— 若真机应答
  /// 果真无计数,首 u32 会被当元素数解析,几乎必然解析弃/降级,安全
  /// 回退逐对象,不产脏数据)。
  ///
  /// 会话级降级([objectPropListDegraded]):真发失败(错误应答/解析
  /// 弃/链路异常)即置位,本会话后续调用秒拒 [UnsupportedError] 不再
  /// 逐枚举浪费 RTT;[open()] 开新会话复位重探(同
  /// [_largeThumbDegraded] 纪律)。不做能力表门禁直发(在册假门)。
  Future<List<PtpObjectProp>> getObjectPropList(
    int handle, {
    int formatCode = 0x00000000,
    int propCode = 0xFFFFFFFF,
    int? groupCode,
    int? depth,
    bool degradeOnFailure = true,
  }) async {
    if (_objectPropListDegraded) {
      throw UnsupportedError('GetObjectPropList(0x9805) 本会话已降级');
    }
    // P4/P5 按位序不可跳:给了任一可选后段参数,P4 组码缺席补 0。
    final params = [handle, formatCode, propCode];
    if (groupCode != null || depth != null) {
      params.add(groupCode ?? 0x00000000);
    }
    if (depth != null) params.add(depth);
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(PtpRequest(
            opcode: NikonOperationCode.getObjectPropList,
            params: params,
          )));
      _ensureOk(result, NikonOperationCode.getObjectPropList);
    } on Exception {
      // 错误应答(op 不在册/参数拒)或链路异常:真发证据,一次失败即
      // 降级本会话([degradeOnFailure] = false 的定向探测除外 —— 探针
      // 拒答只证该形态,不该拖累 App 的批量快路);原异常上抛。
      if (degradeOnFailure) _objectPropListDegraded = true;
      rethrow;
    }
    try {
      return _parseObjectPropList(result.data);
    } on FormatException {
      if (degradeOnFailure) _objectPropListDegraded = true;
      rethrow; // 数据集不可信:整体弃,不产脏数据
    } on ArgumentError {
      // ByteReader 越界(RangeError 族)= 截断数据集,与格式弃同判。
      if (degradeOnFailure) _objectPropListDegraded = true;
      throw const FormatException('GetObjectPropList(0x9805) 数据集截断越界');
    }
  }

  /// 0x9805 ObjectPropList 数据集解析(官方 §6.2.11.5 数据集表):
  /// u32 计数 + N×(u32 句柄 + u16 属性码 + u16 类型 + DTS 值)。
  ///
  /// 防错位三闸(n-link 纪律):①计数与字节流互相印证 —— 提前耗尽或
  /// 解完仍有尾巴都判不可信;②值类型按 [_readObjectPropValue] 定宽读,
  /// 表外未知类型整体抛 [FormatException];③ByteReader 越界(截断)归
  /// 一为 [FormatException]。任一触发 = 本会话降级,回退逐对象。
  static List<PtpObjectProp> _parseObjectPropList(Uint8List? data) {
    // OK 应答零数据/不足计数头:按「空属性表」读(单对象查询的合法形;
    // 全量场景下空表由仓库层按缺口回退补齐,不判失败)。
    if (data == null || data.length < 4) return const [];
    final r = ByteReader(data);
    final count = r.u32();
    final props = <PtpObjectProp>[];
    for (var i = 0; i < count; i++) {
      if (r.remaining < 8) {
        throw FormatException(
            'GetObjectPropList(0x9805) 数据集在第 $i/$count 条提前耗尽');
      }
      final objectHandle = r.u32();
      final code = r.u16();
      final type = r.u16();
      final valueStart = r.offset;
      final value = _readObjectPropValue(r, type);
      props.add(PtpObjectProp(
        handle: objectHandle,
        code: code,
        dataType: type,
        rawValue: Uint8List.sublistView(data, valueStart, r.offset),
        value: value,
      ));
    }
    if (!r.eof) {
      throw FormatException(
          'GetObjectPropList(0x9805) 数据集解完计数 $count 后仍剩 ${r.remaining}B');
    }
    return props;
  }

  /// 0x9805 条目值读取:标准标量直解;**已知宽度的扩展形态**(INT128/
  /// UINT128 0x0009/0x000A —— Zf §6.6.1.13 PersistentUID 在列;数组型
  /// 0x4001-0x4008 u32 元素数 + 元素×N —— §6.6.1.16
  /// RepresentativeSampleData 在列)按宽度跳过不弃解析(值置 null,
  /// rawValue 留档,宽度已知不会错位);**表外未知类型整体抛
  /// [FormatException]**(宁弃不猜,n-link 纪律)。
  static Object? _readObjectPropValue(ByteReader r, int typeCode) {
    switch (typeCode) {
      case 0x0001: // INT8
        _needPropBytes(r, 1);
        return r.u8().toSigned(8);
      case 0x0002: // UINT8
        _needPropBytes(r, 1);
        return r.u8();
      case 0x0003: // INT16
        _needPropBytes(r, 2);
        return r.u16().toSigned(16);
      case 0x0004: // UINT16
        _needPropBytes(r, 2);
        return r.u16();
      case 0x0005: // INT32
        _needPropBytes(r, 4);
        return r.u32().toSigned(32);
      case 0x0006: // UINT32
        _needPropBytes(r, 4);
        return r.u32();
      case 0x0007: // INT64
        _needPropBytes(r, 8);
        return r.u64().toSigned(64);
      case 0x0008: // UINT64
        _needPropBytes(r, 8);
        return r.u64();
      case 0x0009: // INT128:16B 已知宽,Dart int 放不下,跳过不解值
      case 0x000A: // UINT128(§6.6.1.13 PersistentUID)
        _needPropBytes(r, 16);
        r.skip(16);
        return null;
      case 0x4001: // AINT8 ─ 数组:u32 元素数 + 元素×宽
      case 0x4002: // AUINT8(§6.6.1.16 RepresentativeSampleData)
      case 0x4003: // AINT16
      case 0x4004: // AUINT16
      case 0x4005: // AINT32
      case 0x4006: // AUINT32
      case 0x4007: // AINT64
      case 0x4008: // AUINT64
        _needPropBytes(r, 4);
        final n = r.u32();
        final width = switch (typeCode) {
          0x4001 || 0x4002 => 1,
          0x4003 || 0x4004 => 2,
          0x4005 || 0x4006 => 4,
          _ => 8,
        };
        if (n > r.remaining ~/ width) {
          throw FormatException(
              'GetObjectPropList(0x9805) 数组元素数 $n 超出剩余 ${r.remaining}B');
        }
        r.skip(n * width);
        return null;
      case 0xFFFF: // STR:u8 字符数 + UTF-16LE(0xFF = 未提供)
        _needPropBytes(r, 1);
        final n = r.bytes[r.offset];
        if (n != 0xFF) _needPropBytes(r, 1 + 2 * n);
        return r.ptpString();
      default:
        throw FormatException(
            'GetObjectPropList(0x9805) 未知数据集类型 0x${typeCode.toRadixString(16)}(防错位整体弃)');
    }
  }

  /// 0x9805 值读取的剩余字节预检(不足 = 截断数据集)。
  static void _needPropBytes(ByteReader r, int n) {
    if (r.remaining < n) {
      throw FormatException(
          'GetObjectPropList(0x9805) 值字节不足(需 $n 剩 ${r.remaining}B)');
    }
  }

  /// u32 计数 + N×u16 数组解析(0x9801)。
  static List<int> _parseU16Array(Uint8List? data) {
    if (data == null || data.length < 4) return const [];
    final reader = ByteReader(data);
    final count = reader.u32();
    if (count > _kMaxPtpArrayElements || count > reader.remaining ~/ 2) {
      throw FormatException(
          'GetObjectPropsSupported 计数 $count 超出剩余 '
          '${reader.remaining ~/ 2} 项或上限 $_kMaxPtpArrayElements');
    }
    return [for (var i = 0; i < count; i++) reader.u16()];
  }
}
