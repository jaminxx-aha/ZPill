/// PTP 标准操作码 / 响应码 / 事件码 / 设备属性码(ISO 15740)
/// 与尼康厂商扩展码。
///
/// 本文件是**链路无关**的常量家:PTP-IP(TCP 封装)与 PTP/USB
/// (USB Still Image 类)共用同一套码值,仅容器封装不同(见
/// core/ptpip/ 与 core/ptpusb/)。
///
/// 名目基准:libgphoto2 ptp.h;在册性:Zf 真机 GetDeviceInfo
/// (2026-09-27,V3.00:119 操作 / 26 事件 / 21 属性 / 9 格式)逐个核对。
/// 语义未核对的码(0xC125-C128、0xC700 等)不入册;
/// tools/usb_probe 与 tools/ptpip_probe 都会 dump 该响应。
library;

/// PTP 标准操作码(opcode 均为 uint16;以下均为 Zf 实测在册)。
abstract final class PtpOperationCode {
  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002; // 任何操作前必须建立会话
  static const int closeSession = 0x1003;
  static const int getStorageIds = 0x1004;
  static const int getStorageInfo = 0x1005;
  static const int getNumObjects = 0x1006;
  static const int getObjectHandles = 0x1007;
  static const int getObjectInfo = 0x1008;
  static const int getObject = 0x1009;
  static const int getThumb = 0x100A;
  static const int deleteObject = 0x100B;
  static const int initiateCapture = 0x100E; // P3 遥控
  static const int getDevicePropDesc = 0x1014; // 属性描述(心跳探针)
  static const int getDevicePropValue = 0x1015; // P3 曝光查询/设置
  static const int setDevicePropValue = 0x1016;
  static const int getPartialObject = 0x101B; // 32 位偏移分块读(断点续传根基)
}

/// 尼康厂商操作码(Zf 实测在册;名称按 libgphoto2 ptp.h)。
///
/// 注意:zcamera 参考项目的尼康码表已证伪 —— AfDrive 实为 0x90C1、
/// DeviceReady 实为 0x90C8、GetPartialObject 实为 0x101B,勿以其为准。
abstract final class NikonOperationCode {
  static const int initiateCaptureRecInSdram = 0x90C0; // 往 SDRAM 拍一张
  static const int afDrive = 0x90C1; // 自动对焦
  static const int getLargeThumb = 0x90C4;
  static const int getEvent = 0x90C7; // 事件轮询,data-in(旧名 CheckEvent)
  static const int deviceReady = 0x90C8; // 忙等探针
  static const int startLiveView = 0x9201;
  static const int endLiveView = 0x9202;
  static const int getLiveViewImage = 0x9203;
  static const int changeAfArea = 0x9205; // 移动取景对焦区域:两 u32 参数 = 帧像素 x/y(候选,待真机核对)
  static const int afDriveCancel = 0x9206; // 取消自动对焦(候选,待真机核对)
  static const int initiateCaptureRecInMedia = 0x9207;
  static const int getPartialObjectHiSpeed = 0x9400; // handle + 块长 + 终止位
  static const int getEventEx = 0x941C; // 多参数事件
  static const int getObjectSize = 0x9421; // 64 位对象大小,data-in
  static const int getPartialObjectEx = 0x9431; // 64 位偏移+长度 —— Z 系断点续传主力
  static const int getObjectsMetaData = 0x9434;
  // 连接后切「应用模式」(p1=1):Z 系真机口径,不切则相机对遥控写/控制
  // 回 0x200F AccessDenied(OpenZCine:USB 握手在 OpenSession 后必发,
  // 无线 SnapBridge 方言握手同样内置;真机核对)。
  static const int changeApplicationMode = 0x9435;
  // 智能设备配对双op(STA 模式 op 表在册,2026-10-04 Zf 真机;语义按
  // NiConn_DEMO 对 SnapBridge 的抓包分析,真机流程待核对):
  static const int completePairing = 0x935A; // 配对确认(param 0x2001),相机记录本客户端
  static const int getPtpIpPairingCode = 0x952B; // 取配对验证码,data-in
  // Zf 另有大量 0x94xx/0x95xx 码在册但 libgphoto2 未全收录,
  // 需要时以真机行为为准逐个核对补录,禁止臆造名称。
}

/// GetObjectHandles 参数约定(TODO.md §一)。
abstract final class GetObjectHandlesParams {
  /// storage 参数:0xFFFFFFFF 表示全部存储。
  static const int storageAll = 0xFFFFFFFF;

  /// objectFormat 参数:0 表示全部类型(配合浏览器端自行按格式过滤)。
  static const int formatAll = 0x00000000;

  /// parentHandle 参数。规范语义:0x00000000 = 仅根层,0xFFFFFFFF = 全部(递归)。
  /// **Zf 真机(2026-09-27)两者恰好相反**:parentAll 只回根层 2 个 DCIM,
  /// parentRoot(0) 才返回全部 602 个对象 —— 全量枚举必须传 0。
  static const int parentRoot = 0x00000000;
  static const int parentAll = 0xFFFFFFFF;
}

/// PTP 标准响应码(节选;非 OK 需上报 UI,见 TODO.md §一)。
abstract final class PtpResponseCode {
  static const int ok = 0x2001;
  static const int generalError = 0x2002;
  static const int sessionNotOpen = 0x2003;
  static const int invalidTransactionId = 0x2004;
  static const int operationNotSupported = 0x2005;
  static const int parameterNotSupported = 0x2006;
  static const int sessionAlreadyOpen = 0x201E; // probe ensure_session 真机验证:上次会话残留时的 OpenSession 响应
  static const int deviceBusy = 0x2019; // ISO 15740 标准码;尼康忙等探针 0x90C8 的语义响应(Zf 待真机核对)

  // TODO(P1): 按需补充(存储不可用 / 对象不存在等),
  // 以 ISO 15740 §13.4 响应码表为准,禁止臆造。
}

/// 尼康厂商响应码(0xA0xx;名称镜像 libgphoto2 PTP_RC_NIKON_* 符号,
/// 值表来自 OpenZCine PTPOperation.swift,Zf 待真机核对)。
///
/// 对焦/快门路径的常见答语:0xA002 未合焦、0xA004 状态不允许、
/// 0xA00B 未开取景 —— 上层据此转友好提示而非裸十六进制。
abstract final class NikonResponseCode {
  static const int hardwareError = 0xA001;
  static const int outOfFocus = 0xA002;
  static const int changeCameraModeFailed = 0xA003;
  static const int invalidStatus = 0xA004;
  static const int shutterSpeedBulb = 0xA008;
  static const int cameraModeNotAdjustFnumber = 0xA00A;
  static const int notLiveView = 0xA00B;
}

/// PTP 标准事件码(USB interrupt IN / PTP-IP 事件通道上报;
/// 以下均为 Zf 实测在册)。
///
/// 注意标准码是错位的:0x4001 是 CancelTransaction,0x4002 才是
/// ObjectAdded(旧版常量表把 0x4001 当 ObjectAdded,已订正)。
abstract final class PtpEventCode {
  static const int cancelTransaction = 0x4001;
  static const int objectAdded = 0x4002;
  static const int objectRemoved = 0x4003;
  static const int storeAdded = 0x4004;
  static const int storeRemoved = 0x4005;
  static const int devicePropChanged = 0x4006;
  static const int objectInfoChanged = 0x4007;
  static const int deviceInfoChanged = 0x4008;
  static const int requestObjectTransfer = 0x4009;
  static const int storeFull = 0x400A;
  static const int storageInfoChanged = 0x400C; // 0x400B DeviceReset 不在 Zf 码表
  static const int captureComplete = 0x400D;
}

/// 尼康厂商事件码(Zf 实测在册;名称按 libgphoto2 ptp.h)。
abstract final class NikonEventCode {
  static const int objectAddedInSdram = 0xC101; // e1: objecthandle
  static const int captureCompleteRecInSdram = 0xC102;
  static const int movieRecordInterrupted = 0xC105;
  static const int movieRecordComplete = 0xC108;
  static const int movieRecordStarted = 0xC10A;
  static const int liveViewStateChanged = 0xC10C;
  // 0xC125-0xC128、0xC700 也在 Zf 码表内但 libgphoto2 未收录,
  // 待 --events 真机抓包核对语义后再入册。
}

/// 设备属性码。0x50xx 标准区:Zf 真机 GetDeviceInfo 在册(现代尼康走
/// 标准码表,而非旧机身的尼康 0xD0xx);0xD0xx/0xD2xx 厂商区:候选码
/// (值表来自 OpenZCine/libgphoto2,**不在 Zf 在册表内** —— 在册表不是
/// 真相的全部,与 STA 9-op 小表同理,相机可能照常应答;PropDesc 拒答
/// 时目录置空不上屏),全部待真机核对。
abstract final class PtpDevicePropCode {
  static const int batteryLevel = 0x5001;
  static const int imageSize = 0x5003;
  static const int compressionSetting = 0x5004; // 画质/压缩
  static const int whiteBalance = 0x5005;
  static const int fNumber = 0x5007; // 光圈
  static const int focalLength = 0x5008;
  static const int focusMode = 0x500A;
  static const int exposureMeteringMode = 0x500B; // 测光
  static const int flashMode = 0x500C;
  static const int exposureTime = 0x500D; // 快门
  static const int exposureProgramMode = 0x500E; // 曝光模式(P/S/A/M)
  static const int exposureIndex = 0x500F; // ISO
  static const int exposureBiasCompensation = 0x5010; // 曝光补偿
  static const int dateTime = 0x5011;
  static const int stillCaptureMode = 0x5013; // 单张/连拍/自拍
  static const int burstNumber = 0x5018;
  static const int artist = 0x501E;
  static const int copyrightInfo = 0x501F;
  // ---- 厂商候选区(不在 Zf 在册表;语义/类型注为 OpenZCine 实测口径)----
  static const int rawCompressionType = 0xD016; // NEF(RAW)记录压缩,u8
  static const int wbColorTemp = 0xD01E; // 白平衡色温(K),u16
  static const int captureAreaCrop = 0xD030; // 图像区域 FX/DX/1:1/16:9,u8
  static const int stillFocusMode = 0xD061; // 静照对焦模式 AF-S/AF-C/MF/AF-A,u8
  // 曝光写路径(Z 系真机口径,OpenZCine:静照 ISO/快门的标准码 0x500F/
  // 0x500D 只读不可写 —— 写要走厂商码;真机核对):
  static const int exposureIndexEx = 0xD0B4; // ISO 写,u32(值 = ISO 数)
  static const int isoControlSensitivity = 0xD0B5; // 有效 ISO 读(含 Auto ISO),u32
  static const int stillShutterSpeed = 0xD100; // 快门读写,u32 分数打包(num<<16|den)
  static const int applicationMode = 0xD1F0; // 应用模式,u8(一代机身 op 缺席时的写回退)
  static const int activePicCtrlItem = 0xD200; // 优化校准(Picture Control),u16
  // Zf 另报 MTP 标准属性 0xD303/0xD406/0xD407(UseDeviceStageFlag /
  // SessionInitiatorInfo / PerceivedDeviceType,与拍摄无关,不入册)。
  // 色调模式 OpenZCine 记作 0x0001D01C(u32 扩展形态,超 u16 属性码宽;
  // USB 载体会截断成 0xD01C 阴天微调 = 静默错值)—— 不入册,留抓包项。
}
