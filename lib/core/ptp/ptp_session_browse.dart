part of 'ptp_session.dart';

/// 浏览/下载域:对象枚举、存储、缩略、整档/分块下载。
mixin _BrowseOps on _SessionCore {
  bool get largeThumbDegraded => _largeThumbDegraded;

  bool get objectPropListDegraded => _objectPropListDegraded;

  /// GetObjectHandles:u32 计数 + N 个 u32 handle。
  ///
  /// 参数默认值 = Zf 真机语义的全量枚举:**parent 必须传 0**
  /// (GetObjectHandlesParams:Zf 把 0 与 0xFFFFFFFF 的语义做反了)。
  Future<List<int>> getObjectHandles({
    int storageId = GetObjectHandlesParams.storageAll,
    int objectFormat = GetObjectHandlesParams.formatAll,
    int parent = GetObjectHandlesParams.parentRoot,
  }) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getObjectHandles,
          params: [storageId, objectFormat, parent],
        )));
    _ensureOk(result, PtpOperationCode.getObjectHandles);
    return _readU32Array(
        _requireData(result, 'GetObjectHandles'), 'GetObjectHandles');
  }

  /// GetStorageIDs(0x1004):u32 计数 + N 个 u32(双卡槽 = 两个 ID)。
  Future<List<int>> getStorageIds() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: PtpOperationCode.getStorageIds),
        ));
    _ensureOk(result, PtpOperationCode.getStorageIds);
    return _readU32Array(_requireData(result, 'GetStorageIDs'), 'GetStorageIDs');
  }

  /// GetVendorStorageIDs(0x9209,§6.2.3.1):真卡 StorageID 列表。
  ///
  /// application 模式下标准 0x1004 恒回无卡幻影 ID(0x00010000/
  /// 0x00020000,与实际插卡无关 —— 官方明文;0x1005 对幻影 ID 回
  /// 0x2008),有效卡 ID 只能走本码;数据集与 0x1004 同构。
  Future<List<int>> getVendorStorageIds() async {
    final result = await _serialized(() => transport.execute(
          const PtpRequest(opcode: NikonOperationCode.getVendorStorageIds),
        ));
    _ensureOk(result, NikonOperationCode.getVendorStorageIds);
    return _readU32Array(_requireData(result, 'GetVendorStorageIDs'),
        'GetVendorStorageIDs');
  }

  /// GetStorageInfo(0x1005):单存储槽容量/余量(双卡余量展示)。
  Future<CameraStorage> getStorageInfo(int storageId) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(
              opcode: PtpOperationCode.getStorageInfo, params: [storageId]),
        ));
    _ensureOk(result, PtpOperationCode.getStorageInfo);
    return CameraStorage.parse(
        id: storageId, dataset: _requireData(result, 'GetStorageInfo'));
  }

  /// GetObjectInfo:ObjectInfo 数据集与 PTP-IP 同构,复用 ptpip 解析。
  Future<PtpObjectInfo> getObjectInfo(int handle) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getObjectInfo,
          params: [handle],
        )));
    _ensureOk(result, PtpOperationCode.getObjectInfo);
    return PtpObjectInfo.parse(
        handle: handle, dataset: _requireData(result, 'GetObjectInfo'));
  }

  /// DeleteObject(0x100B,标准码):删除相机上的单个对象。
  ///
  /// RAW+JPG 合并组按成员逐个删;被删对象由仓库层出缓存
  /// (ObjectRepository.removeHandles)。**不可逆**,调用方必须弹确认。
  Future<void> deleteObject(int handle) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.deleteObject,
          params: [handle],
        )));
    _ensureOk(result, PtpOperationCode.deleteObject);
  }

  /// GetObject 流式下载:数据容器按块经 [onData] 回调(64KB 级),
  /// **不整体驻留内存** —— 上层边收边写盘。
  Future<void> getObject(
    int handle, {
    required void Function(Uint8List chunk) onData,
  }) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(opcode: PtpOperationCode.getObject, params: [handle]),
          onData: onData,
        ));
    _ensureOk(result, PtpOperationCode.getObject);
  }

  /// GetThumb(0x100A):内嵌缩略图,数据小,整体内存返回。
  Future<Uint8List> getThumb(int handle) async {
    final result = await _serialized(() => transport.execute(
          PtpRequest(opcode: PtpOperationCode.getThumb, params: [handle]),
        ));
    _ensureOk(result, PtpOperationCode.getThumb);
    final data = result.data ?? Uint8List(0);
    // 找不到 SOI 原样返回(旧机身怪布局防御):交上层解码器报错占位。
    return _sniffJpegStart(data) ?? data;
  }

  /// GetPartialObject(0x101B):从 [offset] 起最多 [maxBytes] 字节,
  /// 32 位偏移分块读。不做能力检查(诊断用途:直接观察相机响应码),
  /// 转正断点续传时再加 supportsOperation 门禁。
  Future<Uint8List> getPartialObject(
    int handle,
    int offset,
    int maxBytes,
  ) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: PtpOperationCode.getPartialObject,
          params: [handle, offset, maxBytes],
        )));
    _ensureOk(result, PtpOperationCode.getPartialObject);
    return result.data ?? Uint8List(0);
  }

  /// Nikon GetPartialObjectEx(0x9431,S-SDKZ-200BF §6.2.3.4):
  /// GetPartialObject 的 64 位扩展 —— 偏移与长度各拆 u32 低/高两参,
  /// 规格未记单块上限(0x101B 的 1MB 钳制是实测方言);应答参数携带
  /// 实发字节数(低/高各 u32),**短发合法**,调用方按 offset 续拉,
  /// 不得把中段短读当 EOF。能力探测不查 op 表(无线假门教训:表不可
  /// 信),由调用方真发试探、0x2005/0x2006 即降级 0x101B。
  Future<Uint8List> getPartialObjectEx(
    int handle,
    int offset,
    int maxBytes,
  ) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getPartialObjectEx,
          params: [
            handle,
            offset & 0xFFFFFFFF,
            (offset >> 32) & 0xFFFFFFFF,
            maxBytes & 0xFFFFFFFF,
            (maxBytes >> 32) & 0xFFFFFFFF,
          ],
        )));
    _ensureOk(result, NikonOperationCode.getPartialObjectEx);
    return result.data ?? Uint8List(0);
  }

  /// Nikon GetPartialObjectHighSpeed(0x9400,S-SDKZ-200BF §6.2.3.5):
  /// **游标式顺序整档读** —— 参数只有 (ObjectHandle, TransferMaxSize,
  /// Terminate),无 offset 参,相机自维护读卡游标;规格明文「读卡耗时
  /// 短于 GetPartialObject」,大文件传输首选。**强状态**:游标在整档
  /// 读完 / Terminate=1 / 与上一应答间隔超 ~60s / 卡插拔 / 文件删除 /
  /// 起录像回放 / 一批黑名单命令(GetObjectInfo/GetPartialObjectEx/
  /// GetObjectHandles 等,规格 §6.2.3.5 清单)即释放,再发**从文件头
  /// 重读** —— 只配「下载专态独占会话」使用,随机访问(缩略/头读/
  /// 断点续传)仍归 0x101B/0x9431。应答参 1=实发字节数、参 2/3=执行前
  /// 游标 offset(u32 低/高),调用方逐块对账游标,复位篡流当场现形。
  /// 终止/收场发 Terminate=1(规格:此时数据相恒 0 字节)。前置
  /// application mode ON(连接沿已发 0x9435),没开时相机回
  /// Invalid_Status。黑名单命令一律不得插在游标存续期。
  Future<({Uint8List data, int sentBytes, int cursorOffset})>
      getPartialObjectHighSpeed(
    int handle, {
    required int maxBytes,
    bool terminate = false,
  }) async {
    final result = await _serialized(() => transport.execute(PtpRequest(
          opcode: NikonOperationCode.getPartialObjectHiSpeed,
          params: [handle, maxBytes & 0xFFFFFFFF, terminate ? 1 : 0],
        )));
    _ensureOk(result, NikonOperationCode.getPartialObjectHiSpeed);
    final p = result.params;
    final sent = p.isNotEmpty ? p[0] : (result.data?.length ?? 0);
    final cursor =
        p.length > 2 ? ((p[2] << 32) | (p[1] & 0xFFFFFFFF)) : (p.length > 1 ? p[1] : 0);
    return (
      data: result.data ?? Uint8List(0),
      sentBytes: sent,
      cursorOffset: cursor,
    );
  }

  /// Nikon GetLargeThumb(0x90C4):高清缩略 JPEG(N-link 口径约 1024px,
  /// 单张数百 KB)。相机不支持时抛 [UnsupportedError](上层回落
  /// GetThumb)。
  /// [force] 跳过能力检查直发 —— **生产路径**(缩略图缓存取大图即
  /// force):无线 STA 的 operationsSupported 是假门(9 op 小表常态
  /// 人设,在册校验会拒掉 0x90C4,直发相机却正常回 JPEG —— 2026-10-01
  /// 真机诊断⑥实证;见 memory zf-wifi-mode-gate「勿按表拒连」)。
  ///
  /// 响应字节先做 JPEG SOI 嗅探:非 FFD8 开头时在前 512B 内剥头找
  /// SOI(防御「头 + JPEG」形态);整段无 SOI = 非 JPEG 载荷(如 Zf
  /// 对 NEF 回 320×212 压缩条带,实测定案)→ 视为不支持抛
  /// [UnsupportedError],垃圾字节不进 .jpg 缓存。
  ///
  /// 会话级降级([largeThumbDegraded]):真发一次失败(错误应答/非
  /// SOI/超时断链)即置位,本会话后续调用秒拒 [UnsupportedError] 不再
  /// 逐张浪费 RTT;[open()] 开新会话复位重探(同 [_remoteModeActive]
  /// 「新链新账」纪律)。码表不在册(假门)不置位 —— 真发证据才算数。
  Future<Uint8List> getLargeThumb(int handle, {bool force = false}) async {
    if (!force) {
      // 能力检查走缓存的 GetDeviceInfo(命中时无锁,不会与本方法的锁嵌套)。
      final info = await getDeviceInfo();
      if (!info.supportsOperation(NikonOperationCode.getLargeThumb)) {
        throw UnsupportedError('相机不支持 Nikon GetLargeThumb(0x90C4)');
      }
    }
    if (_largeThumbDegraded) {
      throw UnsupportedError('Nikon GetLargeThumb(0x90C4) 本会话已降级');
    }
    final PtpResult result;
    try {
      result = await _serialized(() => transport.execute(
            PtpRequest(
                opcode: NikonOperationCode.getLargeThumb, params: [handle]),
          ));
      _ensureOk(result, NikonOperationCode.getLargeThumb);
    } on Exception {
      // 错误应答(PtpResponseException)/ 超时(USB 单事务
      // TimeoutException、PTP-IP 看门狗断链 PtpLinkException):一次
      // 失败即降级本会话;原异常上抛(诊断要真相),调用方回落 GetThumb。
      _largeThumbDegraded = true;
      rethrow;
    }
    final data = result.data ?? Uint8List(0);
    final jpeg = _sniffJpegStart(data);
    if (jpeg == null) {
      _largeThumbDegraded = true;
      throw UnsupportedError(
          'Nikon GetLargeThumb(0x90C4) 返回非 JPEG 数据(${data.length}B)');
    }
    return jpeg;
  }
}
