/// Nikon 智能设备模式 GATT UUID(LSS 服务 0xDE00 族,官方定名)。
///
/// 配对/载荷协议见同目录 pairing_engine.dart / geo_payload.dart /
/// time_payload.dart;特征行为速查:
/// - 0x2000 PAIR:indicate,认证握手帧(17B),双向
/// - 0x2002 CLIENT_DEVICE_NAME:写 32B ASCII 控制器名(配对成功后)
/// - 0x2004 CONNECTION_CONFIGURATION:只读 97B(32B SSID+64B 密码+1B 安全,加密)
/// - 0x2005 CONNECTION_ESTABLISHMENT:写 1B,0x01 唤起 WiFi / 0x80 关
/// - 0x2006 CURRENT_TIME:写 10B 校时帧,兼会话心跳
/// - 0x2007 LOCATION_INFORMATION:写 41B 位置帧(GPS 注入主通道)
/// - 0x2008 LSS_CONTROL_POINT(旧代号 NOT1):notify+rw,2B LE 位域
///   `(Connection<<8)|(Location<<4)|Time` —— 相机 notify 请求位
///   (`01 00`=要时间/`10 00`=要定位/`00 01`=要连接),app 清位应答;
///   `01 00` 曾被误读为「配对成功」,实为 TimeRequest
/// - 0x200A LSS_CABLE_ATTACHMENT(旧代号 NOT2):线缆连接态通知
library;

const String kNikonBleService = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharPairing = '00002000-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharName = '00002002-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharConfig = '00002004-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharWifi = '00002005-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharTime = '00002006-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharGeo = '00002007-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharNot1 = '00002008-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharNot2 = '0000200a-3dd4-4255-8d62-6dc7b9bd5561';
/// 0x2003=SERVER_DEVICE_NAME(相机名,SnapBridge 读它取经典蓝牙名供 BTC
/// 发现)、0x2009=LSS_FEATURE(能力位:canBtcCooperation/isConfigWiFi/
/// isCameraControl/isLocationInfo/isTime…)
const String kNikonCharServerName = '00002003-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharFeature = '00002009-3dd4-4255-8d62-6dc7b9bd5561';
/// 0x2001=POWER_CONTROL、0x200B=LSS_SERIAL_NUMBER_STRING(序列号)——
/// 读取面探测用。
const String kNikonCharPowerControl = '00002001-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharSerialString = '0000200b-3dd4-4255-8d62-6dc7b9bd5561';
/// 会话控制面(SnapBridge 方言):0x2020=STATUS_FOR_CONTROL(相机→app
/// 状态 indicate)、0x2021=CONTROL_POINT_FOR_CONTROL(rw+indicate,请求帧
/// `[size u16LE][op u8][保留]`,Configuration op=0x10 = `04 00 10 00`)——
/// 观察订阅,帧内容落诊断日志;方言核实后再决定是否参与状态机。
const String kNikonCharStatusForControl =
    '00002020-3dd4-4255-8d62-6dc7b9bd5561';
const String kNikonCharControlPoint =
    '00002021-3dd4-4255-8d62-6dc7b9bd5561';
/// 0x2A19=BATTERY_LEVEL(标准电量,位于 LSS 服务内;SnapBridge 正常连接
/// 认证后首读 —— A0.a() CHARACTERISTICS_ACCESS 序列)。
const String kNikonCharBattery = '00002a19-3dd4-4255-8d62-6dc7b9bd5561';
