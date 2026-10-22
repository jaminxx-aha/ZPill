#!/usr/bin/env python3
"""ZPill PTP-IP 协议验证 CLI。

在 App 实现之前对真机跑通握手、核对字节布局,再移植进
lib/core/ptpip/codec.dart。参考:libgphoto2 ptpip 后端。

用法:
    python3 probe.py 192.168.1.1
    python3 probe.py --idle 180 192.168.1.1
    python3 probe.py --setprop 0xd406=ZPill/1.0 192.168.1.1
    python3 probe.py --setprop 0xd406= --setprop-layout data 192.168.1.1
    遥控域回归(无线对照 usb_probe 同款):
    python3 probe.py --propdesc 5007,500d,500f 192.168.0.104
    python3 probe.py --liveview 10 192.168.0.104                    # 0x9203 老码
    python3 probe.py --liveview 10 --liveview-op 9428 192.168.0.104 # Ex 码(带头)
    python3 probe.py --liveview 3 --liveview-op 9428 --afarea 3024,1700 192.168.0.104
    python3 probe.py --capture 192.168.0.104                    # 0x100E 标准
    python3 probe.py --capture --capture-op 9207 192.168.0.104  # 尼康候选落卡拍
    python3 probe.py --events 30 192.168.0.104                  # 事件监听窗口

前置:手机/电脑先手动连上相机 WiFi 热点(相机菜单「网络 → 连接至智能设备」)。

验证清单(2026-10-04 14:56 真机全流程通过,退出码 0,结论回填):
- [x] 1-2  command socket + InitCommandRequest/Response —— 方言通过
         (connectionNumber=1,相机名 Z_f_8014411,版本 0x00010000)
- [x] 3    event socket + InitEventResponse(空负载)
- [x] 4    GetDeviceInfo 无会话(tid=0)可用;**119 op 全量画像**;
         小数据集 = StartData+EndData(0 个 Data 包,EndData 带全部载荷)
- [x] 5    OpenSession tid=0 → 0x2001(本轮无残留会话,0x201E 自愈未触发;
         cmd socket 闲置致死后下次运行大概率可验)
- [x] 6    GetObjectHandles:parent=0 → 892 对象(全量),0xFFFFFFFF → 2
         (仅根 DCIM 夹)—— **与 USB 语义一致的反转**,Wi-Fi 同款
- [x] 7    GetObjectInfo 解析正常(句柄线序 = 文件夹在前,与 USB 一致);
         **照片级 GetThumb 已验**(2026-10-04 STA:DSC_5259.JPG 8794B,
         首字节 FFD8 = JPEG SOI)
- [x] 8    **照片级 GetObject 已验**(2026-10-04 STA:DSC_5269.JPG 6995141B,
         declared 与 ObjectInfo 分毫不差;大数据集 = StartData + Data×106
         + EndData 尾包 46817B —— 无线大数据流真容)
- [x] 9    dp 错标宽容:GetDeviceInfo/GetObjectHandles 标 dp=1 数据相照发;
         OpenSession 标 dp=3 照常处理(0x201E,会话已开)—— 相机忽略 dp
- [x] 10   **ProbeRequest 回声在 event socket**(空载荷 → ProbeResponse 0B);
         cmd socket 两种载荷均无回声 —— P2 心跳走 evt 通道
- [x] 11   事件 0x4006(DevicePropChanged,疑电量)tid=0xFFFFFFFF,与 USB 同构
- [x] 12   --setprop 未跑(watcher 未传参)—— 数据出布局仍待验
- [x] 13   CloseSession:cmd socket 已被相机掐死,发不出去(见下)

空闲生命周期(步骤 11 --idle 180 的重大发现):
- **相机 ≤180s 掐死空闲 command socket**(FIN,事务失败;
  相机侧或留悬挂会话,下轮验 0x201E 自愈)
- **event socket 空闲 180s 存活**,还能推事件 —— 长命的是事件通道
- App 设计含义:cmd 通道需要周期 GetDeviceInfo 心跳保活(或断线重连);
  evt 通道适合 ProbeRequest 心跳

真机记录(2026-10-04 二次订正;「步骤 1-2 已验证」系误记、
「智能设备模式是生态门」也系误诊):
- 「连接至智能设备」模式掐线不是生态门,是**方言门**:相机按 SnapBridge
  的 MTP/IP 方言解析 InitCommandRequest —— GUID(尼康安卓客户端固定值
  00112233445566778899AABBCCDDEEFF)+ UTF-16LE 主机名(NUL 结尾,
  **无长度前缀**)+ u32 协议版本 0x00010000。旧失败轮次发的
  「GUID + u32 长度前缀」布局两头不靠:PTPIP.TXT 规范原文与 gphoto2
  尼康实证代码(2026-10-04 核对)都没有长度前缀,规范连版本字段都没有
  (系 gphoto2 追加、相机宽容)—— 当年读完即 FIN 是纯布局错(2026-09-27
  三轮 + 2026-10-04 七连踢)。本探针已改按尼康方言发 —— 依据 Camera_Bridge
  (github.com/HuiLiYiImpl/Camera_Bridge,小米 14 + Zf Wi-Fi 实测通过,
  且其 manifest 无蓝牙权限:BLE 配对不需要)。
- 尼康方言下 Camera_Bridge 的已证行为(本探针待复核):
  GetDeviceInfo tid=0 于 OpenSession 之前可用;OpenSession 也用 tid=0,
  其后事务从 1 起;请求的 DataPhaseInfo 恒发 1(相机宽容错标);
  GetStorageIDs 被 SnapBridge 会话拒绝,枚举用 storage=0xFFFFFFFF
  全存储哨兵 + parent=0;断线恢复 = 双 socket 全量重连重握手。
- 「连接到计算机」(WTU/qDD/darktable 路线)按规范 PTP/IP 方言走,
  是另一条路;本探针不再针对它。
- 服务器为单连接:静默连接会被保持(等 Init),但本端关闭后会「呛住」
  一段时间不接新 SYN(2026-09-27 diag-b、2026-10-04 首轮)——
  **勿发探测性连接**,失败重试要有间隔。

STA 模式结论(2026-10-04 真机,相机入家庭网 192.168.0.104):
- **方言与 AP 完全一致**,无配对门:同一份 Init(连到 AP 全过的字节)
  在 STA 握手/会话/枚举/照片级数据全通过,13 步等效全过。
- **InitFail reason=0x00000001 = 单连接槽位被占**:已配对的 SnapBridge
  在同网段会自动抢占相机,后来者 Init 即被拒(2/2 复现);杀掉 SnapBridge
  重进 STA 即通 —— 不是生态门/配对门。
- **op 表 9 项是 STA 常态人设,与实际能力无关**:0x1001/0x1002/0x1003 +
  6 个 0x9xxx 厂商码(0x935A 0x9439 0x9440 0x9441 0x9442 0x952B),
  连 GetObjectHandles/GetObjectInfo 都不在表,但照片级 GetThumb/
  GetObject 照常 0x2001 —— **勿按表拒连**(AP 那轮是 119 op 全量表,
  同一台相机同一天,两种人设并存)。关机重启不清除该小表。
- 相机在 STA 模式广播 Bonjour **_ptp._tcp**:实例名=设备名(Z_f_8014411),
  TXT 记录 guid(=InitCommandResponse 相机 GUID)/vid=A/pid=453/ver=1/
  apps=NSPP,主机名内嵌 IP(…192-168-000-104.local.)—— App 自动发现
  的现成原料(NSD 浏览即可,零探测连接)。
- 相机 InitCommandResponse 的 GUID 会话间会变(尾 6 字节=MAC 稳定,
  中段变),不是稳定设备标识;断连后相机常自行退出 Wi-Fi 等待态。
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

PORT = 15740
READ_TIMEOUT = 10.0

# 包类型
INIT_CMD_REQ, INIT_CMD_RESP, INIT_EVENT_REQ, INIT_EVENT_RESP, INIT_FAIL = 1, 2, 3, 4, 5
OP_REQ, OP_RESP, EVENT = 6, 7, 8
START_DATA, DATA, CANCEL, END_DATA = 9, 10, 11, 12
PROBE_REQ, PROBE_RESP = 13, 14

PACKET_NAMES = {
    INIT_CMD_REQ: "InitCommandRequest", INIT_CMD_RESP: "InitCommandResponse",
    INIT_EVENT_REQ: "InitEventRequest", INIT_EVENT_RESP: "InitEventResponse",
    INIT_FAIL: "InitFail", OP_REQ: "OperationRequest", OP_RESP: "OperationResponse",
    EVENT: "Event", START_DATA: "StartData", DATA: "Data", CANCEL: "Cancel",
    END_DATA: "EndData", PROBE_REQ: "ProbeRequest", PROBE_RESP: "ProbeResponse",
}

# PTP 操作码
GET_DEVICE_INFO = 0x1001
OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_OBJECT_HANDLES = 0x1007
GET_OBJECT_INFO = 0x1008
GET_OBJECT = 0x1009
GET_THUMB = 0x100A
GET_DEVICE_PROP_DESC = 0x1014
GET_DEVICE_PROP_VALUE = 0x1015
SET_DEVICE_PROP_VALUE = 0x1016

# 遥控域(与 lib/core/ptp/operation_codes.dart 对齐;0x100E 为 ISO 标准,
# 其余尼康候选码 —— STA 的 9 op 小表不含它们,但勿按表拒连,直发摸底)
INITIATE_CAPTURE = 0x100E
NIKON_INITIATE_CAPTURE_REC_IN_MEDIA = 0x9207
NIKON_INITIATE_CAPTURE_REC_IN_SDRAM = 0x90C0
NIKON_START_LIVEVIEW = 0x9201
NIKON_END_LIVEVIEW = 0x9202
NIKON_GET_LIVEVIEW_IMG = 0x9203
NIKON_GET_LIVEVIEW_IMG_EX = 0x9428  # OpenZCine 全系取帧码(ZR dump 实证带 display-info 头)
NIKON_CHANGE_AF_AREA = 0x9205  # p1/p2 = whole-size 坐标(OpenZCine PTPIPClientSession)
NIKON_AF_DRIVE = 0x90C1
NIKON_CHANGE_APPLICATION_MODE = 0x9435  # Z 系方言:遥控 op 前须切应用模式(app enableAppControl 同款)
NIKON_DEVICE_READY = 0x90C8
NIKON_GET_PICTCTRL_DATA = 0x90CC  # 优化校准槽位详情:params[槽位,0],name=数据[3..23) ASCII(libgphoto2 在册;布局 = digiCamControl 实证)
DEVICE_BUSY = 0x2019  # ISO 15740 标准响应码(设备忙)

PTP_OK = 0x2001
SESSION_ALREADY_OPEN = 0x201E

EVENT_NAMES = {
    0x4002: "ObjectAdded(标准)", 0x400D: "CaptureComplete(标准)",
    0xC101: "Nikon_ObjectAddedInSDRAM", 0xC102: "Nikon_CaptureCompleteRecInSdram",
    0xC10C: "Nikon_LiveViewStateChanged(候选,语义未实证)",
    0xC125: "?(gphoto 未收录)", 0xC700: "?(gphoto 未收录)",
    0x4006: "DevicePropChanged(标准;2026-10-04 实测疑电量)",
}

# DataPhaseInfo 取值(libgphoto2 语义,步骤 9 验证)
DP_NO_DATA, DP_DATA_OUT, DP_DATA_IN = 1, 2, 3

# ── 小端编码助手(全部字段小端,大端包会被相机静默丢弃) ──────────────

def u16(v: int) -> bytes:
    return struct.pack("<H", v)

def u32(v: int) -> bytes:
    return struct.pack("<I", v)

def u64(v: int) -> bytes:
    return struct.pack("<Q", v)

def packet(ptype: int, body: bytes = b"") -> bytes:
    """包头:**长度(u32)在前、类型(u32)在后**(均小端,长度含包头 8B)。

    顺序曾写反(类型在前)—— Camera_Bridge 的 packet()/read() 与 libgphoto2
    ptpipheader 均为长度在前,且 Camera_Bridge 在 Zf 上实证工作;旧序从未
    被真机校验过(相机一直 FIN,没解过它发的包头)。
    """
    return u32(len(body) + 8) + u32(ptype) + body

# 尼康安卓客户端(SnapBridge 生态)在 Wi-Fi 上用的固定 GUID
#(Camera_Bridge 真机实证;规范客户端的随机 GUID + 长度前缀布局被拒)
NIKON_ANDROID_GUID = bytes.fromhex("00112233445566778899AABBCCDDEEFF")
PTPIP_VERSION = 0x00010000  # 协议版本 1.0,小端 u32,附在 Init 末尾

def init_command_request(hostname: str) -> bytes:
    """尼康 Wi-Fi 方言(MTP/IP 布局):GUID(16B 固定值)+ UTF-16LE
    主机名(NUL 结尾,**无长度前缀**)+ u32 协议版本。

    规范 PTP/IP 布局(GUID + u32 字节长度 + 主机名)在「连接至智能
    设备」模式下被相机当乱码丢弃(读完即 FIN)—— 见模块 docstring。
    """
    name = (hostname + "\x00").encode("utf-16-le")
    return packet(INIT_CMD_REQ, NIKON_ANDROID_GUID + name + u32(PTPIP_VERSION))

def init_event_request(connection_number: int) -> bytes:
    return packet(INIT_EVENT_REQ, u32(connection_number))

def op_request(opcode: int, params=(), tid: int = 0, dp: int = DP_NO_DATA) -> bytes:
    """DataPhaseInfo(u32) + opcode(u16) + tid(u32) + params(每项 u32)。

    tid 按 u32 编码(USB-IF PTP-IP 规范);若真机按 u16 解读,步骤 5 的
    OP_RESP 回显会立刻暴露 —— 这正是本探针要核对的点。
    """
    return packet(OP_REQ, u32(dp) + u16(opcode) + u32(tid) + b"".join(u32(p) for p in params))

def ptp_str(text: str) -> bytes:
    """PTP 字符串载荷:u8 字符数 + UTF-16LE(usb_probe 同款,0xD406 写入用)。"""
    if len(text) > 255:
        raise ValueError("PTP 字符串最多 255 字符")
    return bytes([len(text)]) + text.encode("utf-16-le")

def start_data(tid: int, total: int) -> bytes:
    return packet(START_DATA, u32(tid) + u64(total))

def data_packet(tid: int, chunk: bytes) -> bytes:
    return packet(DATA, u32(tid) + chunk)

def end_data(tid: int, chunk: bytes) -> bytes:
    return packet(END_DATA, u32(tid) + chunk)

def send_data_out(sock: socket.socket, opcode: int, params, tid: int,
                  payload: bytes, layout: str = "end") -> None:
    """数据出相位:OP_REQ(dp=2)先行,再走 StartData/Data/EndData。

    两种候选布局(真机裁决,回填 Dart transport):
    - end:  StartData + EndData(载荷整体放 EndData)—— 与相机发小数据集的
      数据入形态镜像(步骤 6-8 观测佐证)
    - data: StartData + Data(载荷) + EndData(空)—— 规范全集形态
    """
    sock.sendall(op_request(opcode, params, tid=tid, dp=DP_DATA_OUT))
    sock.sendall(start_data(tid, len(payload)))
    if layout == "end":
        sock.sendall(end_data(tid, payload))
    elif layout == "data":
        for i in range(0, len(payload), 64 * 1024):
            sock.sendall(data_packet(tid, payload[i:i + 64 * 1024]))
        sock.sendall(end_data(tid, b""))
    else:
        raise ValueError(f"未知数据出布局 {layout!r}")

class Tid:
    """事务号分配器(尼康 Wi-Fi 方言,Camera_Bridge 同款):
    无会话 GetDeviceInfo 与 OpenSession 都用 0,其后自增从 1 起。
    peek() 取号不自增(步骤 4 用),next() 取号并自增。
    """

    def __init__(self) -> None:
        self.value = 0

    def peek(self) -> int:
        return self.value

    def next(self) -> int:
        v = self.value
        self.value += 1
        return v

# ── 收包 ────────────────────────────────────────────────────────────

def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(
                "连接被相机关闭 —— 常见原因是字节序/布局错误被静默丢弃"
            )
        buf += chunk
    return buf

def read_packet(sock: socket.socket) -> tuple[int, bytes]:
    length, ptype = struct.unpack("<II", recv_exact(sock, 8))  # 长度在前
    body = recv_exact(sock, length - 8) if length > 8 else b""
    return ptype, body

def parse_op_resp(body: bytes) -> tuple[int, int, list[int]]:
    """响应码(u16) + tid(u32) + params(每项 u32)。"""
    code, tid = struct.unpack_from("<HI", body, 0)
    params = [struct.unpack_from("<I", body, o)[0] for o in range(6, len(body) - 3, 4)]
    return code, tid, params

def parse_event(body: bytes) -> tuple[int, int, list[int]]:
    """事件码(u16) + tid(u32) + params。"""
    return parse_op_resp(body)

def utf16z(buf: bytes, off: int) -> tuple[str, int]:
    """NUL 结尾 UTF-16LE(尼康方言:InitCommandResponse 的相机名用这种)。"""
    end = off
    while end + 1 < len(buf) and buf[end:end + 2] != b"\x00\x00":
        end += 2
    return buf[off:end].decode("utf-16-le"), min(end + 2, len(buf))

def read_data_phase(sock: socket.socket, expect_tid: int, collect: bool = True):
    """读 StartData/Data*/EndData 循环,终至 OP_RESP(数据出事务只回 OP_RESP 也走这里)。

    返回 (payload, stats, resp):
    - payload:collect=False 时只留前 16B(大对象不驻内存,探针也要点脸)
    - stats:declared(StartData u64 总长)/ data_packets / end_payload,
      用于核对「小数据集是否 StartData+EndData 无 Data」
    - resp:(code, tid, params)
    每个数据包的 tid 与 expect_tid 不符时打警告(宽度/回显异常的旁证)。
    """
    payload = b""
    stats = {"declared": None, "data_packets": 0, "end_payload": 0}

    def append(chunk: bytes) -> None:
        nonlocal payload
        payload = payload + chunk if collect else (payload + chunk)[:16]

    while True:
        ptype, body = read_packet(sock)
        if ptype == START_DATA:
            tid, total = struct.unpack_from("<IQ", body, 0)
            if tid != expect_tid:
                print(f"    [warn] StartData tid={tid} 期望 {expect_tid}")
            stats["declared"] = total
        elif ptype == DATA:
            tid = struct.unpack_from("<I", body, 0)[0]
            if tid != expect_tid:
                print(f"    [warn] Data tid={tid} 期望 {expect_tid}")
            stats["data_packets"] += 1
            append(body[4:])
        elif ptype == END_DATA:
            tid = struct.unpack_from("<I", body, 0)[0]
            if tid != expect_tid:
                print(f"    [warn] EndData tid={tid} 期望 {expect_tid}")
            stats["end_payload"] = len(body) - 4
            append(body[4:])
        elif ptype == OP_RESP:
            return payload, stats, parse_op_resp(body)
        else:
            raise ProtocolError(f"数据相中收到意外包 {PACKET_NAMES.get(ptype, ptype)}")

class ProtocolError(Exception):
    pass

def describe(ptype: int, body: bytes) -> str:
    name = PACKET_NAMES.get(ptype, f"Unknown({ptype})")
    if ptype == INIT_CMD_RESP and len(body) >= 4:
        text = f"{name} connectionNumber=0x{struct.unpack('<I', body[:4])[0]:08X}"
        if len(body) >= 24:
            camera_name, off = utf16z(body, 20)
            text += f" cameraGUID={body[4:20].hex().upper()} name={camera_name!r}"
            if off + 4 <= len(body):
                version = struct.unpack_from("<I", body, off)[0]
                text += f" version=0x{version:08X}"
        return text
    if ptype == INIT_FAIL and len(body) >= 4:
        return f"{name} reason=0x{struct.unpack('<I', body[:4])[0]:08X}"
    if ptype == OP_RESP and len(body) >= 6:
        code, tid, _ = parse_op_resp(body)
        return f"{name} code=0x{code:04X} tid={tid}"
    if ptype == EVENT and len(body) >= 6:
        code, tid, _ = parse_event(body)
        return f"{name} code=0x{code:04X} tid={tid}"
    return f"{name} ({len(body)}B)"

# ── ObjectInfo / DeviceInfo 数据集(与 lib/core/ptpip/*.dart 同构) ──

def ptp_string(buf: bytes, off: int) -> tuple[str | None, int]:
    n = buf[off]
    off += 1
    if n == 0:
        return None, off
    return buf[off:off + 2 * n].decode("utf-16-le"), off + 2 * n

def parse_object_info(body: bytes) -> dict:
    """定长头 52B(布局经 USB 真机校验,见 object_info.dart 注释)+ 三串。"""
    (storage_id, obj_format, _prot, size, _thumb_fmt, _thumb_size,
     _thumb_w, _thumb_h, _img_w, _img_h, _depth, parent,
     _assoc_type, _assoc_desc, _seq) = struct.unpack_from("<IHHIHIIIIIIIHII", body, 0)
    filename, off = ptp_string(body, 52)
    capture_date, off = ptp_string(body, off)
    mod_date = None
    if off < len(body):
        mod_date, _ = ptp_string(body, off)
    return {
        "storage": storage_id, "format": obj_format, "size": size,
        "parent": parent, "filename": filename or "",
        "capture": capture_date, "mod": mod_date,
    }

def parse_device_info(body: bytes) -> dict:
    """标准 DeviceInfo 数据集(ISO 15740 §9.3;小端)。"""
    off = 0

    def take(fmt: str):
        nonlocal off
        v = struct.unpack_from(fmt, body, off)[0]
        off += struct.calcsize(fmt)
        return v

    def take_str():
        nonlocal off
        v, off = ptp_string(body, off)
        return v

    def take_arr():
        n = take("<I")
        return [take("<H") for _ in range(n)]

    take("<H")            # StandardVersion
    take("<I")            # VendorExtensionID
    take("<H")            # VendorExtensionVersion
    vendorext = take_str()
    functional_mode = take("<H")
    ops = take_arr()
    events = take_arr()
    props = take_arr()
    take_arr()            # CaptureFormats
    take_arr()            # ImageFormats
    manufacturer = take_str()
    model = take_str()
    device_version = take_str()
    serial = take_str()
    return {
        "vendorext": vendorext, "functional_mode": functional_mode,
        "operations": ops, "events": events, "props": props,
        "manufacturer": manufacturer, "model": model,
        "version": device_version, "serial": serial,
    }

# ── 遥控域摸底件(镜像 usb_probe 同名件;与 Dart device_prop.dart 对齐)──

def cmd_xact(cmd: socket.socket, tid: Tid, opcode: int, params=(),
             dp: int = DP_DATA_IN, collect: bool = True):
    """cmd 通道一次事务(自取 tid),返回 (t, payload, stats, (code, echoed, resp_params))。"""
    t = tid.next()
    cmd.sendall(op_request(opcode, params, tid=t, dp=dp))
    payload, stats, resp = read_data_phase(cmd, t, collect=collect)
    return t, payload, stats, resp

PTP_DTYPES = {
    # typecode -> (struct 格式, 字节宽, 名称);ISO 15740 §9.2
    0x0001: ("<b", 1, "INT8"), 0x0002: ("<B", 1, "UINT8"),
    0x0003: ("<h", 2, "INT16"), 0x0004: ("<H", 2, "UINT16"),
    0x0005: ("<i", 4, "INT32"), 0x0006: ("<I", 4, "UINT32"),
    0x0007: ("<q", 8, "INT64"), 0x0008: ("<Q", 8, "UINT64"),
    0xFFFF: (None, None, "STR"),
}

# ISO 15740 标准属性的数据集类型(与 kStandardPropDataType 对齐)
STANDARD_PROP_DTYPES = {
    0x5001: 0x0002,  # BatteryLevel u8
    0x5007: 0x0004,  # FNumber u16
    0x500D: 0x0006,  # ExposureTime u32
    0x500F: 0x0004,  # ExposureIndex u16
}

def read_ptp_str(buf: bytes, off: int) -> tuple[str, int]:
    n = buf[off]
    off += 1
    if n == 0xFF:
        return "(未提供)", off
    return buf[off:off + 2 * n].decode("utf-16-le", errors="replace"), off + 2 * n

def read_ptp_value(buf: bytes, off: int, dtype: int):
    """按数据集类型读一个值,返回 (值, 下一偏移);未知类型抛 ValueError。"""
    entry = PTP_DTYPES.get(dtype)
    if entry is None:
        raise ValueError(f"未知数据集类型 0x{dtype:04X}")
    fmt, width, _name = entry
    if fmt is None:
        return read_ptp_str(buf, off)
    (v,) = struct.unpack_from(fmt, buf, off)
    return v, off + width

def parse_prop_desc(d: bytes) -> dict:
    """DevicePropDesc 数据集(ISO 15740 §10.5.1.3)防御性解码。

    布局(2026-10-06 订正,gphoto2 ptp_unpack_DPD 权威顺序):
    `u16 code + u16 type + u8 getSet + 出厂默认值 + 当前值 +
    u8 formFlag + FORM` —— **出厂默认值在前,当前值在后**(旧版把
    当前值读在第一位,真机后果 = 光圈永远显示出厂默认 = 镜头最大
    光圈)。与 Dart PtpDevicePropDesc.parse 同策略:值区截断 → 保描述
    弃 FORM;FORM 区异常 → 整组置空。
    """
    r = {"dataType": None, "getSet": None, "current": None, "factory": None,
         "rangeMin": None, "rangeMax": None, "rangeStep": None, "enumValues": None}
    try:
        (_prop, dtype) = struct.unpack_from("<HH", d, 0)
        r["dataType"] = dtype
        if dtype not in PTP_DTYPES:
            return r  # 未知类型码:头部之外不再解读
        r["getSet"] = bool(d[4])
        r["factory"], off = read_ptp_value(d, 5, dtype)
    except (IndexError, struct.error, ValueError):
        return r
    # 当前值(值区第二个;截断数据集可缺)
    values_intact = False
    try:
        if off < len(d):
            r["current"], off = read_ptp_value(d, off, dtype)
            values_intact = True
    except (IndexError, struct.error, ValueError):
        r["current"] = None
    if values_intact and off < len(d):
        try:
            form_flag = d[off]
            off += 1
            if form_flag == 0x01:  # Range FORM:最小 / 最大 / 步长
                r["rangeMin"], off = read_ptp_value(d, off, dtype)
                r["rangeMax"], off = read_ptp_value(d, off, dtype)
                r["rangeStep"], off = read_ptp_value(d, off, dtype)
            elif form_flag == 0x02:  # Enumeration FORM:u16 个数 + N 值
                (count,) = struct.unpack_from("<H", d, off)
                off += 2
                vals = []
                for _ in range(count):
                    v, off = read_ptp_value(d, off, dtype)
                    vals.append(v)
                r["enumValues"] = vals
        except (IndexError, struct.error, ValueError):
            r["rangeMin"] = r["rangeMax"] = r["rangeStep"] = None
            r["enumValues"] = None
    return r

def decode_prop_value(prop: int, d: bytes, dtype_hint: int | None):
    """0x1015 裸值解码,返回 (值, 类型来源说明)。

    顺序:Desc 自描述类型 → ISO 标准表 → 长度嗅探(奇长且符合字符串
    布局 1+2n → STR;1/2/4/8 字节 → u8/u16/u32/u64,与
    PtpDevicePropValue.parse 同规则)。打印来源可直接回答「方言是否
    偏离标准表」。
    """
    n = len(d)
    dtype = None
    source = None
    if dtype_hint is not None and dtype_hint in PTP_DTYPES:
        dtype, source = dtype_hint, "Desc 自描述"
    elif prop in STANDARD_PROP_DTYPES:
        dtype, source = STANDARD_PROP_DTYPES[prop], "ISO 标准表"
    elif n >= 3 and n % 2 == 1 and d[0] == (n - 1) // 2:
        dtype, source = 0xFFFF, "嗅探(字符串布局)"
    elif n in (1, 2, 4, 8):
        dtype, source = {1: 0x0002, 2: 0x0004, 4: 0x0006, 8: 0x0008}[n], \
            "嗅探(字节宽)"
    if dtype is None:
        return None, f"无法嗅探({n}B)"
    try:
        v, _off = read_ptp_value(d, 0, dtype)
    except (IndexError, struct.error, ValueError) as e:
        return None, f"解码失败({e})"
    return v, f"{PTP_DTYPES[dtype][2]} / {source}"

def fmt_event(dt: float, code: int, tid_v: int, params: list[int]) -> str:
    """事件时间线一行:t+时刻 事件码 名称 tid 参数。"""
    name = EVENT_NAMES.get(code, "(未知名)")
    ps = " ".join(f"0x{p:08X}" for p in params)
    return (f"t+{dt * 1000:.0f}ms  0x{code:04X} {name} tid=0x{tid_v:08X}"
            + (f" params=[{ps}]" if ps else ""))

def drain_evt_events(evt: socket.socket, t0: float, timeout: float = 0.2) -> int:
    """排空 evt socket 事件并打印时间线,返回条数(0 = 窗口内无事件)。

    事后恢复 READ_TIMEOUT —— 调用方无需管超时状态。
    """
    evt.settimeout(timeout)
    n = 0
    while True:
        try:
            ptype, body = read_packet(evt)
        except socket.timeout:
            break
        except (ConnectionError, OSError) as e:
            print(f"      [!] event 通道异常({e})—— 停止排空")
            break
        if ptype == EVENT:
            code, tid_v, params = parse_event(body)
            n += 1
            print("      " + fmt_event(time.monotonic() - t0, code, tid_v, params))
        else:
            print(f"      [意外包] {describe(ptype, body)}")
    evt.settimeout(READ_TIMEOUT)
    return n

# ── LiveViewObject 帧头解码(布局源 = OpenZCine PTPLiveViewObject.swift,
#    ZR/Z7 raw dump 实证;Zf 是否同族正是本解码要回答的问题) ──────────

def _be16(p: bytes, o: int) -> int:
    return struct.unpack_from(">H", p, o)[0]

def _be32(p: bytes, o: int) -> int:
    return struct.unpack_from(">I", p, o)[0]

def _angle(p: bytes, o: int) -> str:
    """BE 有符号 16.16 定点角度(度);0xFFFFFFFF = 机身报不可靠。"""
    raw = _be32(p, o)
    if raw == 0xFFFFFFFF:
        return "unreliable"
    v = raw - (1 << 32) if raw >= (1 << 31) else raw
    return f"{v / 65536.0:.3f}°"

def decode_lv_header(p: bytes) -> None:
    """逐域打印 OpenZCine 布局的头字段 + 头部 hex(前 96B 与关键窗口)。"""
    soi = p.find(b"\xff\xd8")
    print(f"      [头解码] len={len(p)} SOI@{soi}")
    if len(p) < 56:
        print("      [头解码] < 56B,无 display-info 头")
        return
    print(f"        jpegLen(BE u32@12)={_be32(p, 12)}"
          f"  wholeSize(BE u16@16/18)={_be16(p, 16)}x{_be16(p, 18)}")
    print(f"        focusResult@42={p[42]} subjectActive@43={p[43]}"
          f" areaCount@44={p[44]} selectedIndex@45={p[45]}"
          f" trackingAF@46={p[46] if len(p) > 46 else '-'}")
    slots = min(max(p[44], 1), 96)
    for i in range(slots):
        base = 48 + i * 8
        if base + 8 > len(p):
            break
        w, h, cx, cy = struct.unpack_from(">HHHH", p, base)
        if w or h:
            print(f"        box[{i}] w={w} h={h} c=({cx},{cy})")
    if len(p) > 828:
        print(f"        recording@828={p[828]} tcOn@831={p[831]}"
              f" tc@832-835={p[832]:02d}:{p[833]:02d}:{p[834]:02d}:{p[835]:02d}"
              f" rotation@839={p[839]}")
    if len(p) >= 852:
        print(f"        level roll@840={_angle(p, 840)} pitch@844={_angle(p, 844)}"
              f" yaw@848={_angle(p, 848)}")
    for lo, hi in ((0, 96), (40, 64), (816, 852)):
        if len(p) < hi:
            continue
        print(f"        hex[{lo:#05x}:{hi:#05x}]:")
        for off in range(lo, min(hi, len(p)), 16):
            row = p[off:off + 16]
            print(f"          {off:04x}  {row.hex(' ')}")

# ── 步骤 5:OpenSession(含 0x201E 自愈,照抄 usb_probe ensure_session) ──

def open_session_with_heal(cmd: socket.socket, tid: Tid, session_id: int = 1) -> int:
    t = tid.next()
    cmd.sendall(op_request(OPEN_SESSION, [session_id], tid=t, dp=DP_NO_DATA))
    ptype, body = read_packet(cmd)
    if ptype != OP_RESP:
        raise ProtocolError(f"OpenSession 未回 OperationResponse,收到 {describe(ptype, body)}")
    code, echoed, _ = parse_op_resp(body)
    print(f"[5] OpenSession tid={t} <- 0x{code:04X} 回显 tid={echoed}")
    if echoed != t:
        print(f"    [发现] tid 回显 {echoed} ≠ 发送 {t}(宽度/起始策略需订正)")
    if code != SESSION_ALREADY_OPEN:
        return code

    print("    0x201E 悬挂会话(上次连接遗留)→ CloseSession 恢复")
    t2 = tid.next()
    cmd.sendall(op_request(CLOSE_SESSION, [], tid=t2, dp=DP_NO_DATA))
    ptype, body = read_packet(cmd)
    if ptype != OP_RESP:
        raise ProtocolError(f"CloseSession 期间收到 {describe(ptype, body)}")
    c2, e2, _ = parse_op_resp(body)
    print(f"    CloseSession tid={t2} <- 0x{c2:04X} 回显 tid={e2}")

    t3 = tid.next()
    cmd.sendall(op_request(OPEN_SESSION, [session_id], tid=t3, dp=DP_NO_DATA))
    ptype, body = read_packet(cmd)
    if ptype != OP_RESP:
        raise ProtocolError(f"重开 OpenSession 收到 {describe(ptype, body)}")
    code, echoed, _ = parse_op_resp(body)
    print(f"    重开 OpenSession tid={t3} <- 0x{code:04X} 回显 tid={echoed}")
    return code

# ── 步骤 10:ProbeRequest 回声(P2 心跳依据) ────────────────────────

def probe_echo(cmd: socket.socket, evt: socket.socket, hostname: str) -> None:
    """四种姿势各给 2s:cmd/evt × 空载荷/GUID+主机名。命中即止。

    ProbeRequest 载荷布局规范语焉不详(libgphoto2 亦未发)—— 空载荷是
    最小形态,GUID+主机名+版本照 InitCommandRequest 抄。回声记录进结论。
    """
    rich = init_command_request(hostname)[8:]  # 与 Init 同款载荷(去包头)
    variants = [
        (cmd, b"", "cmd socket + 空载荷"),
        (cmd, rich, "cmd socket + GUID/主机名载荷"),
        (evt, b"", "evt socket + 空载荷"),
        (evt, rich, "evt socket + GUID/主机名载荷"),
    ]
    for sock, payload, label in variants:
        try:
            sock.sendall(packet(PROBE_REQ, payload))
            sock.settimeout(2.0)
            ptype, body = read_packet(sock)
        except socket.timeout:
            print(f"[10] {label}:2s 无回声")
            continue
        except (ConnectionError, OSError) as e:
            print(f"[10] {label}:链路异常({e})—— ProbeRequest 可能被视为非法包")
            return
        print(f"[10] {label} <- {describe(ptype, body)}")
        if ptype == PROBE_RESP:
            print("    [结论] ProbeRequest 有回声(载荷见上)—— P2 心跳可用")
            return
        if ptype in (EVENT,):
            print("    (推来的是事件,非回声;换下一姿势)")
    print("[10] 四种姿势均无 ProbeResponse —— 心跳不可用,保活另寻他路")
    cmd.settimeout(READ_TIMEOUT)
    evt.settimeout(READ_TIMEOUT)

# ── 握手流程 ─────────────────────────────────────────────────────────

def connect_camera(host: str, port: int, attempts: int = 4) -> socket.socket:
    """首连重试:SYN 无响应在相机侧不留状态,可安全重试。

    覆盖两个场景:用户刚入 AP、相机 15740 尚未监听;以及本机刚关闭过一个
    空连接、相机 accept 循环还在回收(2026-10-04 真机:探测性连接关闭后
    3s,新 SYN 无人接 —— 对相机勿发探测性连接)。
    """
    last: OSError | None = None
    for i in range(1, attempts + 1):
        try:
            return socket.create_connection((host, port), timeout=5)
        except OSError as e:
            last = e
            print(f"[1] 连接尝试 {i}/{attempts} 失败:{e}")
            if i < attempts:
                time.sleep(5)
    assert last is not None
    raise last


def main() -> int:
    ap = argparse.ArgumentParser(description="PTP-IP 真机验证(尼康 Z 系列)")
    ap.add_argument("host", nargs="?", default="192.168.1.1", help="相机 IP,默认 192.168.1.1")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--hostname", default="Android Device",
                    help="InitCommandReq 主机名(尼康方言默认 Android Device,Camera_Bridge 实证值)")
    ap.add_argument("--idle", type=int, default=0, metavar="SECONDS",
                    help="步骤 11 后双 socket 空闲保持 N 秒,再测存活(观测相机会否踢空闲连接)")
    ap.add_argument("--setprop", type=str, metavar="hex=text", action="append",
                    help="步骤 12:唯一写操作,仅 0xD406(USB 已证下次连接自动弹回出厂)。"
                         "text 为字面值,空文本 = 清空")
    ap.add_argument("--setprop-layout", choices=("end", "data"), default="end",
                    help="数据出布局:end=StartData+EndData(载荷);data=StartData+Data+空EndData")
    ap.add_argument("--propdesc", type=lambda s: [int(x, 16) for x in s.split(",")],
                    metavar="hex[,hex…]", default=[],
                    help="步骤 9r:Desc/Value 解码对照(镜像 Dart device_prop.dart"
                         " 的类型表/长度嗅探/FORM/MTP 出厂组,打印类型来源)"
                         "—— 曝光三属性回归:--propdesc 5007,500d,500f")
    ap.add_argument("--liveview", type=int, metavar="帧数", default=0,
                    help="步骤 9v:Live View 摸底 0x9201 → 取帧轮询 N 帧"
                         "(间隔 200ms 对齐 app;连续 5 帧失败收口)→ 0x9202;"
                         "帧率/字节数/SOI 偏移/单帧往返延迟 + evt 事件时间线")
    ap.add_argument("--liveview-op", type=lambda s: int(s, 16), metavar="hex",
                    default=NIKON_GET_LIVEVIEW_IMG,
                    help="取帧操作码:0x9203(默认,老 GetLiveViewImage)/"
                         "0x9428(GetLiveViewImageEx,OpenZCine 全系取帧码,"
                         "应答带 display-info 头:对焦框/水平仪/录制态)")
    ap.add_argument("--afarea", type=str, metavar="x,y", default=None,
                    help="步骤 9v 内:取完 N 帧后发 0x9205 ChangeAfArea(x,y),"
                         "再取 8 帧看对焦框移动(0x9205 坐标系实证;"
                         "whole-size 空间如 6048x3400 的中心 = 3024,1700)")
    ap.add_argument("--capture", action="store_true",
                    help="步骤 9c:快门释放摸底(--capture-op 换码)+ evt 事件"
                         "时间线 + 0x90C8 DeviceReady 忙等收口")
    ap.add_argument("--capture-op", type=lambda s: int(s, 16), metavar="hex",
                    default=INITIATE_CAPTURE,
                    help="拍照操作码:0x100E(标准,默认)/ 0x9207 / 0x90C0"
                         "(尼康候选,配合 --capture)")
    ap.add_argument("--events", type=int, metavar="秒", default=0,
                    help="步骤 9e:evt 通道监听 N 秒(期间在相机上按快门/"
                         "转波轮),事件时间线带名称与参数")
    ap.add_argument("--picctrl", action="store_true",
                    help="步骤 9w:优化校准 0xD200 摸底(usb_probe --picctrl "
                         "的无线对照):FORM 枚举全量 + 每槽位 0x90CC "
                         "GetPictCtrlData 读注册名(自定义/云组真名)")
    args = ap.parse_args()

    try:
        cmd = connect_camera(args.host, args.port)
    except OSError as e:
        print(f"[1] 无法连接 {args.host}:{args.port}({e})"
              f"—— 检查相机 Wi-Fi 是否开着、Mac 是否在热点上")
        return 2
    cmd.settimeout(READ_TIMEOUT)
    print(f"[1] TCP 已连接 {args.host}:{args.port}(command 通道)")

    # 步骤 1-2:Init Command Request → Response
    try:
        cmd.sendall(init_command_request(args.hostname))
        ptype, body = read_packet(cmd)
    except (ConnectionError, socket.timeout, OSError) as e:
        print(f"[2] InitCommandRequest 握手失败({e})")
        print("    已按尼康方言发(固定 GUID + NUL 主机名 + 版本)仍被掐 ——")
        print("    请确认相机在「网络 → 连接至智能设备」的等待连接状态;")
        print("    若相机在「连接到计算机」模式,它期待规范 PTP/IP 方言,")
        print("    请切回「连接至智能设备」再试。日志带回给 Claude。")
        return 2
    print(f"[2] <- {describe(ptype, body)}")
    if ptype == INIT_FAIL:
        print("    InitFail:检查主机名编码(UTF-16LE)与长度字段(u32)")
        return 1
    if ptype != INIT_CMD_RESP:
        print(f"    意外包类型 {ptype},期望 {INIT_CMD_RESP}")
        return 1
    connection_number = struct.unpack("<I", body[:4])[0]

    # 步骤 3:event socket 独立握手(InitEventRequest 必须发在它上面)
    evt = socket.create_connection((args.host, args.port), timeout=5)
    evt.settimeout(READ_TIMEOUT)
    print(f"[3] event 通道 TCP 已连接")
    evt.sendall(init_event_request(connection_number))
    ptype, body = read_packet(evt)
    print(f"    <- {describe(ptype, body)}")
    if ptype != INIT_EVENT_RESP:
        print(f"    意外包类型 {ptype},期望 INIT_EVENT_RESP({INIT_EVENT_RESP})")
        cmd.close()
        evt.close()
        return 1

    tid = Tid()

    # 步骤 4:无会话 GetDeviceInfo(tid=0,peek 不自增 —— OpenSession 也用 0)。
    # USB 语义允许会话外调用;App 的 connect 流程(受限画像检测)依赖它,
    # PTP/IP 是否放行必须先证。
    t = tid.peek()
    try:
        cmd.sendall(op_request(GET_DEVICE_INFO, [], tid=t, dp=DP_DATA_IN))
        payload, stats, (code, echoed, _) = read_data_phase(cmd, t)
    except (ConnectionError, socket.timeout, ProtocolError) as e:
        print(f"[4] 无会话 GetDeviceInfo:链路异常({e})—— PTP/IP 不允许,App 流程需改为 OpenSession 后取")
        return 1
    print(f"[4] 无会话 GetDeviceInfo tid={t} <- 0x{code:04X} 回显 tid={echoed} "
          f"{stats['declared']}B Data×{stats['data_packets']} EndData={stats['end_payload']}B")
    if code == PTP_OK:
        info = parse_device_info(payload)
        print(f"    model={info['model']} version={info['version']} "
              f"functionalMode=0x{info['functional_mode']:04X} ops={len(info['operations'])}")
        if GET_OBJECT not in info["operations"]:
            print("    [发现] op 表缺 GetObject —— 受限画像态(USB 见过 23 op 副面孔)")
        if len(info["operations"]) < 30:
            print(f"    op 表({len(info['operations'])}): "
                  f"{' '.join(f'0x{o:04X}' for o in info['operations'])}")
    else:
        print("    [发现] 会话外 GetDeviceInfo 非 OK —— App 需先 OpenSession")

    # 步骤 5:OpenSession(sessionId=1;0x201E 悬挂会话自愈)
    code = open_session_with_heal(cmd, tid)
    if code != PTP_OK:
        print(f"[5] OpenSession 失败:0x{code:04X}")
        return 1

    # 步骤 6:GetObjectHandles —— parent=0 与 0xFFFFFFFF 对比(Zf USB 上语义反转)。
    # 尼康方言注意:SnapBridge 会话下 GetStorageIDs 被拒(Camera_Bridge 实证),
    # 枚举一律用 storage=0xFFFFFFFF 全存储哨兵 —— 本探针不碰 StorageIDs。
    handles_all: list[int] = []
    for parent in (0, 0xFFFFFFFF):
        t = tid.next()
        cmd.sendall(op_request(GET_OBJECT_HANDLES, [0xFFFFFFFF, 0, parent],
                               tid=t, dp=DP_DATA_IN))
        payload, stats, (code, echoed, _) = read_data_phase(cmd, t)
        print(f"[6] GetObjectHandles parent=0x{parent:08X} <- code=0x{code:04X} "
              f"tid={echoed} {stats['declared']}B "
              f"Data×{stats['data_packets']} EndData={stats['end_payload']}B")
        if code != PTP_OK:
            continue
        count = struct.unpack_from("<I", payload, 0)[0]
        handles = [struct.unpack_from("<I", payload, 4 + 4 * i)[0] for i in range(count)]
        print(f"    对象数 = {count}(handle 前 5:{[hex(h) for h in handles[:5]]})")
        if parent == 0:
            handles_all = handles
    if not handles_all:
        print("    parent=0 未取得对象,中止")
        return 1

    # 步骤 7:前几个句柄的 GetObjectInfo(句柄线序 = 夹子在前,USB 实测两槽
    # 各约 10 夹、照片紧随其后)—— 夹子验结构,照片验数据;窗口 40 越过夹子段
    infos: list[tuple[int, dict]] = []
    for h in handles_all[:40]:
        t = tid.next()
        cmd.sendall(op_request(GET_OBJECT_INFO, [h], tid=t, dp=DP_DATA_IN))
        payload, stats, (code, _, _) = read_data_phase(cmd, t)
        if code != PTP_OK:
            print(f"[7] GetObjectInfo 0x{h:08X} <- 0x{code:04X}")
            continue
        info = parse_object_info(payload)
        infos.append((h, info))
        print(f"[7] 0x{h:08X} format=0x{info['format']:04X} size={info['size']} "
              f"parent=0x{info['parent']:08X} file={info['filename']} "
              f"capture={info['capture']}")
    if not infos:
        print("    没有可用的 ObjectInfo,中止")
        return 1
    photos = [(h, i) for h, i in infos
              if i["format"] != 0x3001 and i["size"] > 0]  # 0x3001=文件夹
    if not photos:
        print("    前 40 个句柄没有照片,GetThumb/GetObject 下轮再验")
        return 0

    t = tid.next()
    thumb_h = photos[0][0]
    cmd.sendall(op_request(GET_THUMB, [thumb_h], tid=t, dp=DP_DATA_IN))
    payload, stats, (code, _, _) = read_data_phase(cmd, t)
    print(f"[7] GetThumb 0x{thumb_h:08X}({photos[0][1]['filename']}) <- 0x{code:04X} "
          f"{len(payload)}B (declared={stats['declared']}) "
          f"首 4 字节 = {payload[:4].hex().upper()}")

    # 步骤 8:最小照片的 GetObject —— 数据相形态与总量对账
    smallest_h, smallest = min(photos, key=lambda kv: kv[1]["size"])
    t = tid.next()
    cmd.sendall(op_request(GET_OBJECT, [smallest_h], tid=t, dp=DP_DATA_IN))
    _, stats, (code, echoed, _) = read_data_phase(cmd, t, collect=False)
    total = (stats["declared"] or 0)
    print(f"[8] GetObject 0x{smallest_h:08X}({smallest['filename']},{smallest['size']}B)"
          f" <- 0x{code:04X} tid={echoed} declared={total} "
          f"Data×{stats['data_packets']} EndData={stats['end_payload']}B")
    if total and total != smallest["size"]:
        print(f"    [发现] StartData 总长 {total} ≠ ObjectInfo.compressedSize "
              f"{smallest['size']}")

    # 步骤 9:DataPhaseInfo 错标容忍(放最后:搞乱会话不伤已到手结论)。
    # 先验预期:宽容 —— 尼康客户端请求里 dp 恒发 1(Camera_Bridge 实证)。
    try:
        t = tid.next()
        cmd.sendall(op_request(GET_DEVICE_INFO, [], tid=t, dp=DP_NO_DATA))
        payload, stats, (code, echoed, _) = read_data_phase(cmd, t)
        has_data = stats["declared"] is not None
        print(f"[9] GetDeviceInfo dp=1(实际应为 3)<- 0x{code:04X} "
              f"数据相={'有' if has_data else '无'}"
              f"{'(declared=%d)' % stats['declared'] if has_data else ''}")
        if has_data:
            print("    [发现] dp=1 时数据相照发 —— 相机忽略/宽容错标 dp")
    except (ConnectionError, socket.timeout, ProtocolError) as e:
        print(f"[9] GetDeviceInfo dp=1:链路异常({e})—— 相机对错标 dp 不宽容")
        cmd.close()
        evt.close()
        return 0
    try:
        t = tid.next()
        cmd.sendall(op_request(GET_OBJECT_HANDLES, [0xFFFFFFFF, 0, 0],
                               tid=t, dp=DP_NO_DATA))
        payload, stats, (code, echoed, _) = read_data_phase(cmd, t)
        has_data = stats["declared"] is not None
        print(f"[9] GetObjectHandles dp=1(实际应为 3)<- 0x{code:04X} "
              f"数据相={'有' if has_data else '无'} "
              f"Data×{stats['data_packets']}")
        if code != PTP_OK:
            print(f"    [发现] 错标 dp 得非 OK 响应码 0x{code:04X}")
    except (ConnectionError, socket.timeout, ProtocolError) as e:
        print(f"[9] GetObjectHandles dp=1:链路异常({e})")
    try:
        t = tid.next()
        cmd.sendall(op_request(OPEN_SESSION, [1], tid=t, dp=DP_DATA_IN))
        payload, stats, (code, echoed, _) = read_data_phase(cmd, t)
        print(f"[9] OpenSession dp=3(实际应为 1;会话已开,响应码预期 0x201E)"
              f"<- 0x{code:04X}")
    except (ConnectionError, socket.timeout, ProtocolError) as e:
        print(f"[9] OpenSession dp=3:链路异常({e})—— 会话操作错标不宽容")

    # 步骤 9r(可选,--propdesc):Desc/Value 解码对照 —— 无线链路的遥控
    # 域回归。与 usb_probe --propdesc 同款(镜像 Dart device_prop.dart 的
    # 解码链:类型来源 Desc 自描述 → ISO 标准表 → 长度嗅探;FORM 范围/
    # 枚举 + MTP 出厂组)。USB/无线两份输出对拍,方言差异一目了然。
    if args.propdesc:
        print("[9r] 设备属性 Desc/Value 解码对照:")
        for prop in args.propdesc:
            dtype_hint = None
            try:
                t, payload, stats, (code, echoed, _) = cmd_xact(
                    cmd, tid, GET_DEVICE_PROP_DESC, [prop], dp=DP_DATA_IN)
            except (ConnectionError, socket.timeout, ProtocolError) as e:
                print(f"  0x{prop:04X} Desc:链路异常({e})—— 中止本步")
                break
            if code == PTP_OK:
                print(f"  0x{prop:04X} Desc <- OK {len(payload)}B "
                      f"declared={stats['declared']} Data×{stats['data_packets']} "
                      f"EndData={stats['end_payload']}B")
                print(f"    raw: {payload[:64].hex(' ')}"
                      + (" …" if len(payload) > 64 else ""))
                desc = parse_prop_desc(payload)
                dtype_hint = desc["dataType"]
                if dtype_hint is not None and dtype_hint not in PTP_DTYPES:
                    print(f"    解码: DataType=0x{dtype_hint:04X}(未知类型码,头部外不解读)")
                else:
                    tname = PTP_DTYPES[dtype_hint][2] if dtype_hint is not None else "?"
                    print(f"    解码: DataType={tname}  getSet={desc['getSet']}"
                          f"({'可写' if desc['getSet'] else '只读'})"
                          f"  current={desc['current']!r}")
                    if desc["rangeMin"] is not None:
                        print(f"    FORM 范围: {desc['rangeMin']!r} ~ {desc['rangeMax']!r}"
                              f" 步长 {desc['rangeStep']!r}")
                    if desc["enumValues"]:
                        vals = desc["enumValues"]
                        print(f"    FORM 枚举({len(vals)}): "
                              + " ".join(repr(v) for v in vals[:12])
                              + (" …" if len(vals) > 12 else ""))
                    if desc["factory"]:
                        print(f"    MTP 出厂组: {desc['factory']!r}")
            else:
                print(f"  0x{prop:04X} Desc <- 0x{code:04X}")
            try:
                t, payload, stats, (code, echoed, _) = cmd_xact(
                    cmd, tid, GET_DEVICE_PROP_VALUE, [prop], dp=DP_DATA_IN)
            except (ConnectionError, socket.timeout, ProtocolError) as e:
                print(f"  0x{prop:04X} Value:链路异常({e})—— 中止本步")
                break
            if code == PTP_OK:
                print(f"  0x{prop:04X} Value <- OK {len(payload)}B "
                      f"raw: {payload[:48].hex(' ')}")
                v, src = decode_prop_value(prop, payload, dtype_hint)
                print(f"    解码: {src} -> {v!r}")
            else:
                print(f"  0x{prop:04X} Value <- 0x{code:04X}")

    # 步骤 9v(可选,--liveview N):Live View 轮询摸底(无线对照)。
    # 0x9201 → 取帧轮询直到 N 帧成功(间隔 200ms 对齐 app;连续 5 帧
    # 失败收口,LiveViewEngine 同策略)→ 0x9202。帧率/字节数/SOI 偏移/
    # 单帧往返延迟 + evt 事件时间线(0xC10C 取景态变迁语义在此落定)。
    # 取帧码 --liveview-op:0x9203(老码,历史实证应答)vs 0x9428
    # (GetLiveViewImageEx,OpenZCine 全系取帧码,应答带 display-info
    # 头 = 对焦框/水平仪/录制态的唯一数据源)—— 2026-10-07 真机
    # 「0x9203 帧头解析全 null」后加,对拍两码的应答形态。
    # STA 的 9 op 小表不含 0x920x/0x9428 —— 按表拒连即误杀的教训,直发摸底。
    # 步骤 9v 前量:Z 系方言 —— 遥控 op(0x9201/0x9205/0x9207…)前须发
    # 0x9435(1) 切应用模式,否则相机对遥控 op 直接关闭连接(2026-10-07
    # Zf STA 实证:无 0x9435 的 0x9201 一发即断链;app 连接流同款先发)。
    app_mode_sent = False

    def ensure_app_mode():
        nonlocal app_mode_sent
        if app_mode_sent:
            return
        app_mode_sent = True
        try:
            _t, _p, _s, (c, e, _) = cmd_xact(
                cmd, tid, NIKON_CHANGE_APPLICATION_MODE, [1], dp=DP_NO_DATA)
            print(f"    ChangeApplicationMode(0x9435,1) <- 0x{c:04X} 回显 tid={e}")
        except (ConnectionError, socket.timeout, ProtocolError) as ex:
            print(f"    ChangeApplicationMode(0x9435,1):链路异常({ex})")

    if args.liveview:
        fetch_op = args.liveview_op
        print(f"[9v] Live View 摸底(0x9201 → 0x{fetch_op:04X} ×{args.liveview} 帧 → 0x9202):")
        ensure_app_mode()
        t0 = time.monotonic()
        try:
            t, payload, stats, (code, echoed, _) = cmd_xact(
                cmd, tid, NIKON_START_LIVEVIEW, dp=DP_NO_DATA)
            print(f"    StartLiveView <- 0x{code:04X} 回显 tid={echoed}")
        except (ConnectionError, socket.timeout, ProtocolError) as e:
            print(f"    StartLiveView:链路异常({e})")
            code = -1
        if code == PTP_OK:
            drain_evt_events(evt, t0)
            sizes, latencies, soi_hist = [], [], {}
            fails = got = attempt = 0
            while got < args.liveview and fails < 5:
                time.sleep(0.2)  # 开取景后相机就绪需拍前摇,失败亦同拍重试
                attempt += 1
                t_x = time.monotonic()
                try:
                    t, payload, stats, (code, echoed, _) = cmd_xact(
                        cmd, tid, fetch_op, dp=DP_DATA_IN)
                except (ConnectionError, socket.timeout, ProtocolError) as e:
                    print(f"    尝试 #{attempt} <- 链路异常({e})—— 停止轮询")
                    break
                latencies.append(time.monotonic() - t_x)
                drain_evt_events(evt, t0)
                if code != PTP_OK:
                    print(f"    尝试 #{attempt} <- 0x{code:04X}"
                          f" declared={stats['declared']}"
                          f" Data×{stats['data_packets']}")
                    fails += 1
                    continue
                fails = 0
                got += 1
                soi = payload.find(b"\xff\xd8")
                sizes.append(len(payload))
                soi_hist[soi] = soi_hist.get(soi, 0) + 1
                print(f"    帧 #{got}: {len(payload)}B SOI@{soi} "
                      f"declared={stats['declared']} Data×{stats['data_packets']}")
                if got == 1:
                    ext = ".jpg" if soi >= 0 else ".bin"
                    out = f"/tmp/zpill_ptpip_liveview_first{ext}"
                    with open(out, "wb") as f:
                        f.write(payload)
                    print(f"      头 32B: {payload[:32].hex(' ')}  原始帧已存:{out}")
                    decode_lv_header(payload)
            elapsed = max(time.monotonic() - t0, 1e-6)
            print(f"    小结:取得 {got}/{args.liveview} 帧(失败 {fails} 连击即止)"
                  f"  用时 {elapsed:.1f}s  实测帧率 {got / elapsed:.1f}fps")
            if sizes:
                print(f"    帧大小:min {min(sizes)}B / 均值 {sum(sizes) // len(sizes)}B"
                      f" / max {max(sizes)}B")
            if latencies:
                ms = sorted(x * 1000 for x in latencies)
                print(f"    单帧事务往返:min {ms[0]:.0f}ms / 中位 {ms[len(ms) // 2]:.0f}ms"
                      f" / max {ms[-1]:.0f}ms(无线对照 USB;app 间隔 200ms 是否够看这里)")
            if soi_hist:
                print("    SOI 偏移直方图: "
                      + "  ".join(f"@{k}×{v}" for k, v in sorted(soi_hist.items())))

            # 9v-a(可选,--afarea x,y):0x9205 ChangeAfArea 坐标系实证 ——
            # 发指定坐标,取 8 帧看对焦框(box[0])是否移动到位。whole-size
            # 空间(头 @16/18)与 SOF 帧像素空间各试一次即可分辨坐标系。
            if args.afarea and got > 0:
                ax, ay = (int(v) for v in args.afarea.split(","))
                print(f"    [9v-a] ChangeAfArea(0x9205) x={ax} y={ay}:")
                try:
                    t, payload, stats, (code, echoed, _) = cmd_xact(
                        cmd, tid, NIKON_CHANGE_AF_AREA, [ax & 0xFFFFFFFF, ay & 0xFFFFFFFF],
                        dp=DP_NO_DATA)
                    print(f"      ChangeAfArea <- 0x{code:04X} 回显 tid={echoed}")
                except (ConnectionError, socket.timeout, ProtocolError) as e:
                    print(f"      ChangeAfArea:链路异常({e})")
                    code = -1
                if code == PTP_OK:
                    for i in range(8):
                        time.sleep(0.25)
                        try:
                            t, payload, stats, (code, echoed, _) = cmd_xact(
                                cmd, tid, fetch_op, dp=DP_DATA_IN)
                        except (ConnectionError, socket.timeout, ProtocolError) as e:
                            print(f"      帧 a#{i + 1} <- 链路异常({e})")
                            break
                        if code != PTP_OK:
                            print(f"      帧 a#{i + 1} <- 0x{code:04X}")
                            continue
                        soi = payload.find(b"\xff\xd8")
                        if len(payload) >= 56:
                            w, h, cx, cy = struct.unpack_from(">HHHH", payload, 48)
                            print(f"      帧 a#{i + 1}: box[0] w={w} h={h} c=({cx},{cy})"
                                  f" focusResult@42={payload[42]} areaCount@44={payload[44]}"
                                  f" SOI@{soi}")
                        else:
                            print(f"      帧 a#{i + 1}: {len(payload)}B SOI@{soi}(无头)")
            try:
                t, payload, stats, (code, echoed, _) = cmd_xact(
                    cmd, tid, NIKON_END_LIVEVIEW, dp=DP_NO_DATA)
                print(f"    EndLiveView <- 0x{code:04X}")
            except (ConnectionError, socket.timeout, ProtocolError) as e:
                print(f"    EndLiveView:链路异常({e})")
            drain_evt_events(evt, t0)  # 0xC10C 若在停止时推送,语义在此落定

    # 步骤 9w(可选,--picctrl):优化校准(0xD200)槽位摸底 —— usb_probe
    # --picctrl 的无线对照。FORM 枚举全量 + 每槽位 0x90CC GetPictCtrlData
    # 读注册名(自定义/云组真名;布局 = digiCamControl 实证:[0]未知
    # [1]单色 [2]自定义 [3..23) ASCII 名 NUL 截断)。0x90CC 属厂商读,
    # 9-op 小表外 —— 按表拒连即误杀的教训直发;0x9435 前量同 9v 保险。
    if args.picctrl:
        print("[9w] 优化校准 0xD200 摸底(FORM 全量 + 0x90CC 槽位名):")
        ensure_app_mode()
        slots = []
        try:
            t, payload, stats, (code, echoed, _) = cmd_xact(
                cmd, tid, GET_DEVICE_PROP_DESC, [0xD200], dp=DP_DATA_IN)
        except (ConnectionError, socket.timeout, ProtocolError) as e:
            print(f"  0xD200 Desc:链路异常({e})—— 中止本步")
            code = -1
        if code == PTP_OK:
            desc = parse_prop_desc(payload)
            print(f"  Desc <- OK {len(payload)}B  getSet={desc['getSet']}"
                  f"({'可写' if desc['getSet'] else '只读'})"
                  f"  current={desc['current']!r}")
            slots = list(desc["enumValues"] or [])
            if slots:
                print(f"  FORM 枚举({len(slots)}): " + " ".join(str(v) for v in slots))
            else:
                print("  FORM 枚举:无(只读裸值?—— 46 项清单得靠机身菜单)")
        else:
            print(f"  Desc <- 0x{code:04X}(FORM 拿不到,跳过槽位名)")
        for slot in slots:
            try:
                t, payload, stats, (code, echoed, _) = cmd_xact(
                    cmd, tid, NIKON_GET_PICTCTRL_DATA, [slot, 0], dp=DP_DATA_IN)
            except (ConnectionError, socket.timeout, ProtocolError) as e:
                print(f"  0x90CC({slot}):链路异常({e})—— 中止槽位循环")
                break
            if code == PTP_OK:
                name = (payload[3:23].split(b"\x00")[0].decode("ascii", "replace")
                        if len(payload) >= 23 else "")
                mono = payload[1] if len(payload) > 1 else -1
                custom = payload[2] if len(payload) > 2 else -1
                print(f"  0x90CC({slot}) <- OK {len(payload)}B  mono={mono}"
                      f" custom={custom}  name={name!r}")
                print("      " + payload[:48].hex(" "))
            else:
                print(f"  0x90CC({slot}) <- 0x{code:04X}")

    # 步骤 9c(可选,--capture):快门释放摸底(无线对照)—— 0x100E(标准)
    # /0x9207/0x90C0(尼康候选)发一次,evt 事件时间线 + 0x90C8 DeviceReady
    # 忙等收口(300ms×30,长曝余量;就绪后再听 2s 收 ObjectAdded 拖尾)。
    # 事件语义(CaptureComplete 先后/双格式双 ObjectAdded/0xC10C)以此
    # 时间线落定,回填 RemoteController 消费表;与 usb_probe --capture 对拍。
    if args.capture:
        names = {INITIATE_CAPTURE: "InitiateCapture 0x100E(标准)",
                 NIKON_INITIATE_CAPTURE_REC_IN_MEDIA:
                     "InitiateCaptureRecInMedia 0x9207(候选)",
                 NIKON_INITIATE_CAPTURE_REC_IN_SDRAM:
                     "InitiateCaptureRecInSdram 0x90C0(候选)"}
        label = names.get(args.capture_op, f"0x{args.capture_op:04X}")
        print(f"[9c] 快门释放摸底({label},参数 0,0):")
        ensure_app_mode()
        t0 = time.monotonic()
        try:
            t, payload, stats, (code, echoed, _) = cmd_xact(
                cmd, tid, args.capture_op, [0, 0], dp=DP_NO_DATA)
            print(f"    t+0ms  op <- 0x{code:04X} 回显 tid={echoed}")
        except (ConnectionError, socket.timeout, ProtocolError) as e:
            print(f"    t+0ms  op <- 链路异常({e})")
            code = -1
        if code == PTP_OK:
            drain_evt_events(evt, t0)
            for i in range(30):  # 300ms × 30 ≈ 9s:app 的 10×300ms 放宽,长曝余量
                time.sleep(0.3)
                drain_evt_events(evt, t0)
                t_x = time.monotonic()
                try:
                    t, payload, stats, (code2, echoed, _) = cmd_xact(
                        cmd, tid, NIKON_DEVICE_READY, dp=DP_NO_DATA)
                except (ConnectionError, socket.timeout, ProtocolError) as e:
                    print(f"    DeviceReady:链路异常({e})—— 停止忙等")
                    break
                dt = (time.monotonic() - t_x) * 1000
                if code2 == PTP_OK:
                    print(f"    t+{(time.monotonic() - t0) * 1000:.0f}ms  "
                          f"DeviceReady <- OK(落地,第 {i + 1} 轮,事务 {dt:.0f}ms)")
                    break
                if code2 == DEVICE_BUSY:
                    print(f"    t+{(time.monotonic() - t0) * 1000:.0f}ms  "
                          f"DeviceReady <- 0x2019 忙(事务 {dt:.0f}ms)")
                    continue
                print(f"    DeviceReady <- 0x{code2:04X}(非忙,放弃兜底 —— "
                      "命令已被接受,等事件即可)")
                break
            # 就绪后再听 2s:ObjectAdded 常晚于 CaptureComplete/就绪
            end = time.monotonic() + 2.0
            while time.monotonic() < end:
                if drain_evt_events(evt, t0, timeout=0.2):
                    continue
                time.sleep(0.2)

    # 步骤 9e(可选,--events N):evt 通道监听窗口 —— 期间在相机上任意
    # 操作(半按快门/拍一张/转波轮/开关取景),事件时间线带名称与参数。
    # --idle 骨架的监听件(空闲保持仍归 --idle,两不相扰)。
    if args.events > 0:
        print(f"[9e] 事件监听窗口 {args.events}s —— 现在在相机上按快门/转波轮…")
        t0 = time.monotonic()
        deadline = t0 + args.events
        n = 0
        evt.settimeout(0.5)
        while time.monotonic() < deadline:
            try:
                ptype, body = read_packet(evt)
            except socket.timeout:
                continue
            except (ConnectionError, OSError) as e:
                print(f"    [!] event 通道异常({e})—— 窗口终止")
                break
            if ptype == EVENT:
                code, tid_v, params = parse_event(body)
                n += 1
                print("    " + fmt_event(time.monotonic() - t0, code, tid_v, params))
            else:
                print(f"    [意外包] {describe(ptype, body)}")
        evt.settimeout(READ_TIMEOUT)
        if n == 0:
            print("    (窗口内无事件;试试期间按快门/转波轮)")

    # 步骤 10:ProbeRequest 回声
    probe_echo(cmd, evt, args.hostname)

    # 步骤 11:窥探 event socket(操作期间相机可能推过事件)
    evt.settimeout(0.5)
    try:
        while True:
            ptype, body = read_packet(evt)
            print(f"[11] event <- {describe(ptype, body)}")
            if ptype == INIT_EVENT_RESP:
                continue  # 迟到的握手响应?打出来看看
            if ptype == EVENT:
                code, tid_v, params = parse_event(body)
                print(f"    事件码 0x{code:04X} tid={tid_v} params={[hex(p) for p in params]}")
    except socket.timeout:
        print("[11] event 通道 0.5s 内无事件")
    except (ConnectionError, OSError):
        print("[11] event 通道已关闭")
    evt.settimeout(READ_TIMEOUT)

    # --idle:空闲保持后双 socket 存活性(观测相机会否踢空闲连接)
    if args.idle > 0:
        print(f"[hold] 双 socket 空闲保持 {args.idle}s(不给任何流量)…")
        remaining = args.idle
        while remaining > 0:
            chunk = min(10, remaining)
            time.sleep(chunk)
            remaining -= chunk
            if remaining > 0:
                print(f"    … 还剩 {remaining}s")
        evt.settimeout(2.0)
        try:
            ptype, body = read_packet(evt)
            print(f"[hold] 空闲后 event <- {describe(ptype, body)}(通道活着)")
        except socket.timeout:
            print("[hold] 空闲后 event socket:2s 无数据(通道未关、无事件)")
        except (ConnectionError, OSError) as e:
            print(f"[hold] 空闲后 event socket 已死({e})—— 相机踢了空闲 event 通道!")
        evt.settimeout(READ_TIMEOUT)
        t = tid.next()
        try:
            cmd.sendall(op_request(GET_DEVICE_INFO, [], tid=t, dp=DP_DATA_IN))
            _, stats, (code, _, _) = read_data_phase(cmd, t)
            print(f"[hold] 空闲后 cmd socket 事务存活:GetDeviceInfo <- 0x{code:04X}")
        except (ConnectionError, socket.timeout, ProtocolError) as e:
            print(f"[hold] 空闲后 cmd socket 已死({e})")

    # 步骤 12:--setprop 唯一写操作(0xD406 SessionInitiatorInfo;
    # USB 真机已证:可写、回读生效、下次连接自动弹回出厂值)
    if args.setprop:
        print(f"[12] SetDevicePropValue 数据出({args.setprop_layout} 布局):")
        for spec in args.setprop:
            if "=" not in spec:
                print(f"    [格式错 {spec!r}:应为 十六进制属性码=文本(如 0xd406=ZPill/1.0)]")
                continue
            code_s, text = spec.split("=", 1)
            try:
                prop = int(code_s, 16)
            except ValueError:
                print(f"    [格式错 {spec!r}:属性码应为十六进制]")
                continue
            payload = ptp_str(text)
            print(f"  ▶ 0x{prop:04X}={text!r}(载荷 {len(payload)}B)")
            t = tid.next()
            try:
                send_data_out(cmd, SET_DEVICE_PROP_VALUE, [prop], t,
                              payload, args.setprop_layout)
                _, stats, (code, echoed, _) = read_data_phase(cmd, t)
                print(f"    SetDevicePropValue <- 0x{code:04X} 回显 tid={echoed}")
            except (ConnectionError, socket.timeout, ProtocolError) as e:
                print(f"    SetDevicePropValue:链路异常({e})—— {args.setprop_layout} 布局被拒,"
                      f"换 --setprop-layout { 'data' if args.setprop_layout == 'end' else 'end' } 重试")
                cmd.close()
                evt.close()
                return 0
            if code != PTP_OK:
                continue
            # 回读验证
            t = tid.next()
            cmd.sendall(op_request(GET_DEVICE_PROP_VALUE, [prop], tid=t, dp=DP_DATA_IN))
            back, _, (code2, _, _) = read_data_phase(cmd, t)
            if code2 == PTP_OK and back:
                n = back[0]
                text_back = back[1:1 + 2 * n].decode("utf-16-le", errors="replace") if n else ""
                print(f"    回读 <- 0x{code2:04X} {text_back!r}(写入生效={text_back == text})")

    # 步骤 13:CloseSession 收尾(不留悬挂会话;App 的 session.close() 同款)
    t = tid.next()
    try:
        cmd.sendall(op_request(CLOSE_SESSION, [], tid=t, dp=DP_NO_DATA))
        ptype, body = read_packet(cmd)
        code, echoed, _ = parse_op_resp(body)
        print(f"[13] CloseSession tid={t} <- 0x{code:04X} 回显 tid={echoed}(探针退出)")
    except (ConnectionError, socket.timeout, ProtocolError) as e:
        print(f"[13] CloseSession 异常({e})—— 可能留下悬挂会话,下次运行验步骤 5 自愈")

    cmd.close()
    evt.close()
    print("[OK] 全流程跑完;把上面 [发现] 与各步骤输出回填 lib/core/ptpip/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
