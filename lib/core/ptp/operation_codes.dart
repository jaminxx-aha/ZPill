/// PTP 标准操作码 / 响应码 / 事件码 / 设备属性码(ISO 15740)
/// 与尼康厂商扩展码。
///
/// 本文件是**链路无关**的常量家:PTP-IP(TCP 封装)与 PTP/USB
/// (USB Still Image 类)共用同一套码值,仅容器封装不同(见
/// core/ptpip/ 与 core/ptpusb/)。
///
/// 名目基准:libgphoto2 ptp.h;在册性:Zf 真机 GetDeviceInfo
/// (2026-09-27,V3.00:119 操作 / 26 事件 / 21 属性 / 9 格式)逐个核对。
/// 2026-10-12 起名目/语义第二权威 = 官方 Zf USB MTP 指令书
/// (sdk/S-SDKZ-200BF-ALLIN,Rev 2.00;响应码 §6.3 / 事件码 §6.4 /
/// 属性码 §6.5 每码一节)—— 官方无条目的码(0xC120-C124、0xC128、
/// 0xC700 等)仍不入册;tools/usb_probe 与 tools/ptpip_probe 都会
/// dump 该响应。
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
  // 切换「remote / PC-camera」模式(p1=1 remote / 0 PC-camera):remote
  // 即「APP 接管控制」—— 机身拨盘锁定,host 写入的会话值(连拍上限等)
  // 仅在持有期保值;释放/AF/清洁中会被拒(0xA003)。源 = OpenZCine
  // (全系在册)与 libgphoto2 同码;真机核对。
  static const int changeCameraMode = 0x90C2;
  static const int getLargeThumb = 0x90C4;
  static const int getEvent = 0x90C7; // 事件轮询,data-in(旧名 CheckEvent)
  static const int deviceReady = 0x90C8; // 忙等探针
  // 读优化校准(0xD200)槽位详情:data-in 应答布局按 digiCamControl
  // NikonBase.GetPictureControl 实证 —— params [槽位号(即 0xD200 值), 0],
  // 数据 [0]=未知 [1]=单色标志 [2]=自定义标志 [3..22]=20 字节 ASCII 名
  // (NUL 截断)[23+]=调节值曲线;libgphoto2 ptp.h 在册(同组 0x90CD 写
  // 0x90CE 删 0x90CF 能力);Zf 待真机核对。
  static const int getPictCtrlData = 0x90CC;
  static const int startLiveView = 0x9201;
  static const int endLiveView = 0x9202;
  static const int getLiveViewImage = 0x9203;
  // 取帧主力码(OpenZCine 全系在册、无回退路径):应答 = display-info
  // 头(大端:对焦框数组/水平仪/录制态/旋转)+ JPEG。老码 0x9203 在
  // Zf 上应答解析不出头(2026-10-07 真机),取景引擎一律先 0x9428。
  static const int getLiveViewImageEx = 0x9428;
  // 移动取景对焦区域:两 u32 参数 = 帧头 whole-size 坐标系 x/y
  // (OpenZCine recentre = coordinateWidth/2 实证;非 JPEG 像素)。
  static const int changeAfArea = 0x9205;
  // 取消进行中的 AF 驱动(2026-10-12 官方指令书 §6.2.5.2 定名
  // AfDriveCancel,无参无数据;未接线,候选保留)。
  static const int afDriveCancel = 0x9206;
  static const int mfDrive = 0x9204; // 手动对焦步进:params [方向(1=近/2=远), 脉冲数 1..32767](OpenZCine 同款;相对量,无绝对位置读出)
  static const int initiateCaptureRecInMedia = 0x9207;
  static const int startMovieRecInCard = 0x920A // 开始卡上录制(无参无数据;OpenZCine 同款)
      ;
  static const int endMovieRec = 0x920B; // 结束卡上录制(无参无数据)
  static const int terminateCapture = 0x920C; // 终止连拍/Bulb(参数 [0,0],已拍保留;源 = OpenZCine terminateStillCapture)
  static const int getPartialObjectHiSpeed = 0x9400; // handle + 块长 + 终止位
  static const int getEventEx = 0x941C; // 多参数事件
  static const int getObjectSize = 0x9421; // 64 位对象大小,data-in
  static const int getPartialObjectEx = 0x9431; // 64 位偏移+长度 —— Z 系断点续传主力
  static const int getObjectsMetaData = 0x9434;
  // 连接后切「应用模式」(p1=1):Z 系真机口径,不切则相机对遥控写/控制
  // 回 0x200F AccessDenied(OpenZCine:USB 握手在 OpenSession 后必发,
  // 无线 SnapBridge 方言握手同样内置;真机核对)。
  static const int changeApplicationMode = 0x9435;
  // Gen-3 Ex 属性 ops(0x0001_xxxx 扩展属性码专用;2 字节码用标准 ops,
  // 混用会拒/断连 —— OpenZCine 实测口径):读描述/读值/写值。
  static const int getDevicePropDescEx = 0x943A;
  static const int getDevicePropValueEx = 0x943B;
  static const int setDevicePropValueEx = 0x943C;
  // 智能设备配对双op(STA 模式 op 表在册,2026-10-04 Zf 真机;语义按
  // NiConn_DEMO 对 SnapBridge 的抓包分析,真机流程待核对):
  static const int completePairing = 0x935A; // 配对确认(param 0x2001),相机记录本客户端
  static const int getPtpIpPairingCode = 0x952B; // 取配对验证码,data-in
  // ── 官方指令书候选区(2026-10-12 §6.2 定名入册,项目未接线;真机
  // 在册性以接线时行为为准)。主体追踪启停(参数同 0x9205):
  static const int startTracking = 0x9424;
  static const int endTracking = 0x9425;
  // AE/AWB 锁:P1 0 释放/1 锁,P2 锁类型(pdf 表列错位,编码前重对
  // §6.2.4.5;应答 OK 仍须读 AELockStatus/AWBLockStatus §6.5.6.5/8 确认)。
  static const int changeAELock = 0x9426;
  static const int clearEvent = 0x9461; // 清相机事件队列(重连沿清残留可试)
  static const int changeMonitorOff = 0x9422; // 机内屏关/开(监看省电)
  // 电动变焦(PZ 镜头):P1 启/停、P2 方向 1 广角/2 望远/3 定位置、
  // P3 速度 0-10(菜单 -5~+5)、P4 目标位置;§2.12 位置存储/召回。
  static const int powerZoomDrive = 0x9464;
  // 相机设置备份/恢复(拍摄配置快照的官方替代路)。
  static const int saveCameraSetting = 0x9420;
  static const int getCameraSettingData = 0x946D;
  static const int sendCameraSettingData = 0x946E;
  static const int getLiveViewCompressedSize = 0x9423; // 当前帧压缩长度
  static const int getFhdPicture = 0x920F; // SDRAM 对象的 FHD JPEG(无则 0xA00F)
  static const int afAndCaptureRecInSdram = 0x90CB; // AF+SDRAM 拍一体
  // 开放捕获族(长时连拍/B 门高速取数的候选,语义接线时对 §6.2.4.7-9)。
  static const int initiateOpenCaptureV = 0x9445;
  static const int terminateOpenCaptureV = 0x9446;
  static const int getOpenCaptureInfo = 0x9447;
  // 4 字节扩展码正规通道:0x9439 查厂商码全表(param 0x09=厂商 op /
  // 0x0D=厂商属性,u32 数组),0x9440-42 包装执行 4 字节 op(P1=扩展码、
  // P2-5=透传参数;带数据相的命令不能走 0x9440)。现有 Ex 属性 ops
  // (0x943A-C)之外的第 2 条官方路,解 0x0001_xxxx 载体截断。
  static const int getVendorCodes = 0x9439;
  static const int operationDataNone = 0x9440;
  static const int operationReceiveData = 0x9441;
  static const int operationSendData = 0x9442;
  // MTP 对象属性组(§6.2.11,initiator 写非 MTP 身份后 op 表 124 时的
  // 对象级元数据批量通道;0x9804 不应答与身份的因果待厘清)。
  static const int getObjectPropsSupported = 0x9801;
  static const int getObjectPropDesc = 0x9802;
  static const int getObjectPropValue = 0x9803;
  static const int setObjectPropValue = 0x9804;
  static const int getObjectPropList = 0x9805;
  // Zf 另有大量 0x94xx/0x95xx 码在册但 libgphoto2 未全收录,
  // 需要时以真机行为为准逐个核对补录,禁止臆造名称(官方指令书 §6.2
  // 已给全名目,补录以它为准)。
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
  static const int storeNotAvailable = 0x2013; // ISO 15740 标准码(存储不可用/无卡;2026-10-06 真机:0x100E 报过此码)
  static const int accessDenied = 0x200F; // ISO 15740 标准码(未切应用模式/拨盘拥有时遥控写被拒,真机实证)
  static const int deviceBusy = 0x2019; // ISO 15740 标准码;尼康忙等探针 0x90C8 的语义响应(Zf 待真机核对)
  static const int invalidParameter = 0x201D; // ISO 15740 标准码(参数域拒;2026-10-06 真机:0x9207 的 [0,0] CaptureSort 在应用模式/接管态被拒)
  static const int sessionAlreadyOpen = 0x201E; // probe ensure_session 真机验证:上次会话残留时的 OpenSession 响应

  // TODO(P1): 按需补充(对象不存在等),以 ISO 15740 §13.4 响应码表为准,禁止臆造。
}

/// 尼康厂商响应码(0xA0xx;名称镜像 libgphoto2 PTP_RC_NIKON_* 符号;
/// 2026-10-12 起在册性与语义以官方指令书 §6.3.2 为准 —— 全表 23 码,
/// 值表此前按 OpenZCine 预填的 9 码已逐码对上,余码为官方名直译)。
///
/// 对焦/快门路径的常见答语:0xA002 未合焦、0xA004 状态不允许、
/// 0xA00B 未开取景 —— 上层据此转友好提示而非裸十六进制;
/// 忙族 0xA200/0xA201/0xA202 见 nico 差集(B 门/静音快门/录像中静照)。
abstract final class NikonResponseCode {
  static const int hardwareError = 0xA001;
  static const int outOfFocus = 0xA002;
  static const int changeCameraModeFailed = 0xA003;
  static const int invalidStatus = 0xA004;
  static const int wbPresetError = 0xA006; // 预设白平衡测量释放失败
  static const int dustReferenceError = 0xA007; // 除尘参照图拍摄失败
  static const int shutterSpeedBulb = 0xA008;
  static const int cameraModeNotAdjustFnumber = 0xA00A; // 光圈 F- 档
  static const int notLiveView = 0xA00B;
  static const int mfDriveStepEnd = 0xA00C; // MF 步进行程尽头(结果而非错误)
  static const int mfDriveStepInsufficiency = 0xA00E; // MF 步进量过小未动
  static const int noFullHdPresent = 0xA00F; // 0x920F GetFhdPicture 无 FHD 数据
  static const int storeError = 0xA021; // 含损坏卡
  static const int storeUnformatted = 0xA022; // 含未格式化卡
  static const int bulbReleaseBusy = 0xA200; // B 门拍摄进行中
  static const int silentReleaseBusy = 0xA201; // 静音快门拍摄进行中
  static const int movieFrameReleaseBusy = 0xA202; // 录像中静照释放进行中
  static const int shutterSpeedTime = 0xA204; // 快门 Time 档
  static const int invalidData = 0xA210; // 数据相内容不当
  static const int invalidObjectPropCode = 0xA801; // MTP 对象属性组(0x98xx 族)
  static const int invalidObjectPropFormat = 0xA802;
  static const int invalidObjectPropValue = 0xA803;
  static const int objectPropNotSupported = 0xA80A; // 码合法但相机不支持
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

/// 尼康厂商事件码(名称按 libgphoto2 ptp.h;2026-10-12 起在册性以
/// 官方指令书 §6.4 为准 —— 下列全部在 Zf 事件表内。0xC10B/0xC10F/
/// 0xC126 三码**只走 GetEventEx 轮询通道**,中断/0x90C7 不送)。
abstract final class NikonEventCode {
  static const int objectAddedInSdram = 0xC101; // e1: objecthandle
  static const int captureCompleteRecInSdram = 0xC102;
  static const int captureSkip = 0xC103; // 连拍跳帧
  static const int movieRecordInterrupted = 0xC105;
  static const int movieRecordComplete = 0xC108;
  static const int movieRecordStarted = 0xC10A;
  static const int pictureControlAdjustChanged = 0xC10B; // 仅 GetEventEx
  static const int liveViewStateChanged = 0xC10C;
  static const int pixelMappingComplete = 0xC10D; // 像素映射(除尘)完成
  static const int manualSettingLensDataChanged = 0xC10E; // 非 CPU 镜头数据
  static const int openCaptureComplete = 0xC10F; // 仅 GetEventEx
  static const int hlgQualityAdjustChanged = 0xC125;
  static const int portraitImpressionBalanceAdjustChanged = 0xC126; // 仅 GetEventEx
  static const int pictureControlHlgAdjustChanged = 0xC127;
  // 0xC120-0xC124、0xC128、0xC700 在 Zf DeviceInfo 事件表内但官方文档
  // 无条目,语义仍欠 —— 待 --events 真机抓包核对后再入册。
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
  static const int stillIsoAutoControl = 0xD054; // 静照自动 ISO 开关,u8(0=手动/1=自动;OpenZCine stillISOAutoControl)
  static const int stillFocusMeteringMode = 0xD05D; // 静照 AF 区域模式,u16(Zf FORM 七值:单点/自动/精确/宽S/宽L/宽C1/宽C2 —— 无 动态区域/3D 追踪,2026-10-07 USB 实证;标签见 shooting_param_catalog)
  static const int exposureRemaining = 0xD1F1 // 剩余可拍张数(OpenZCine exposureRemaining;读出用)
      ;
  // 曝光写路径(Z 系真机口径,OpenZCine:静照 ISO/快门的标准码 0x500F/
  // 0x500D 只读不可写 —— 写要走厂商码;真机核对):
  static const int exposureIndexEx = 0xD0B4; // ISO 写,u32(值 = ISO 数)
  static const int isoControlSensitivity = 0xD0B5; // 有效 ISO 读(含 Auto ISO),u32
  static const int stillShutterSpeed = 0xD100; // 快门读写,u32 分数打包(num<<16|den)
  static const int applicationMode = 0xD1F0; // 应用模式,u8(一代机身 op 缺席时的写回退)
  static const int liveViewSelector = 0xD1A6; // 照片/视频模式镜像,u8(0=照片/1=视频,机顶拨杆决定;2026-10-11 Zf USB 实证:0x90C2(1) 持有下 0x1016 可写覆写、随释放还原,拍照门跟此值、录像门跟物理拨杆硬互锁;不在 Zf 自报属性表,范围扫得见)
  static const int sessionInitiatorInfo = 0xD406; // 会话发起者身份(MTP 标准;USB 人设身份门,自愈末级用,见 LiveViewEngine._startLiveViewHealing)
  static const int activePicCtrlItem = 0xD200; // 优化校准(Picture Control),u16
  // 镜头规格实时属性(只读;2026-10-12 Zf USB 探针定案:**不在
  // devicePropsSupported 声明表但 0x1015 应答** —— 读取绕声明表门禁;
  // 挂 40 SE 实测 4000/4000/200/200 = 40-40mm ƒ/2-ƒ/2,与 0x5008 的
  // 0.01mm、0x5007 的 ƒ×100 同族定点。gphoto nikon 表同族码)。
  static const int lensFocalLengthMin = 0xD0E3; // 焦距下限,u32(0.01mm)
  static const int lensFocalLengthMax = 0xD0E4; // 焦距上限,u32(0.01mm)
  static const int lensMaxApertureWide = 0xD0E5; // 广角端最大光圈,u16(ƒ×100)
  static const int lensMaxApertureTele = 0xD0E6; // 远摄端最大光圈,u16(ƒ×100)
  // 挂机镜头 ID(u16,官方 Zf USB MTP 指令书 6.5.10.4:每镜唯一,未挂
  // 固定 0;协议无镜头名属性,营销名靠 ID→名映射表,2026-10-12 Zf USB
  // 探针实证不在声明表但应答:40 SE=25、24-120 ƒ/4 S=31)。
  static const int lensId = 0xD0E0;
  // 机身警告状态位掩码(u32 只读,官方 §6.5.6.24;Bit0=序列错误 ——
  // 快门失败提示可指名,恢复口径官方 §11.7.5)。
  static const int warningStatus = 0xD102;
  // Zf 另报 MTP 标准属性 0xD303/0xD407(UseDeviceStageFlag /
  // PerceivedDeviceType,与拍摄无关,不入册)。
  // 色调模式 OpenZCine 记作 0x0001D01C(u32 扩展形态,超 u16 属性码宽;
  // USB 载体会截断成 0xD01C 阴天微调 = 静默错值)—— 不入册,留抓包项。
}
