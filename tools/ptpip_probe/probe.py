#!/usr/bin/env python3
"""NikonBridge PTP-IP 协议验证 CLI(TODO.md §一 P0)。

在 App 实现之前对真机跑通握手、核对字节布局,再移植进
lib/core/ptpip/codec.dart。参考:libgphoto2 ptpip 后端。

用法:
    python3 probe.py 192.168.1.1
    python3 probe.py --hostname MacBook 192.168.1.1

前置:手机/电脑先手动连上相机 WiFi 热点。
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import uuid

PORT = 15740

# 包类型(TODO.md §一)
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
OPEN_SESSION = 0x1002
GET_OBJECT_HANDLES = 0x1007

# ── 小端编码助手(全部字段小端,大端包会被相机静默丢弃) ──────────────

def u16(v: int) -> bytes:
    return struct.pack("<H", v)

def u32(v: int) -> bytes:
    return struct.pack("<I", v)

def u64(v: int) -> bytes:
    return struct.pack("<Q", v)

def packet(ptype: int, body: bytes = b"") -> bytes:
    """包头:类型(u32)+ 长度(u32,含包头自身 8 字节)。"""
    return u32(ptype) + u32(len(body) + 8) + body

def init_command_request(hostname: str) -> bytes:
    """GUID(16B) + 主机名长度(u32,注意是 4 字节) + UTF-16LE 主机名。"""
    guid = uuid.uuid4().bytes[:16]
    name = hostname.encode("utf-16-le")
    return packet(INIT_CMD_REQ, guid + u32(len(name)) + name)

def init_event_request(connection_number: int) -> bytes:
    return packet(INIT_EVENT_REQ, u32(connection_number))

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
    ptype, length = struct.unpack("<II", recv_exact(sock, 8))
    body = recv_exact(sock, length - 8) if length > 8 else b""
    return ptype, body

def describe(ptype: int, body: bytes) -> str:
    name = PACKET_NAMES.get(ptype, f"Unknown({ptype})")
    if ptype == INIT_CMD_RESP and len(body) >= 4:
        return f"{name} connectionNumber=0x{struct.unpack('<I', body[:4])[0]:08X}"
    if ptype == INIT_FAIL and len(body) >= 4:
        return f"{name} reason=0x{struct.unpack('<I', body[:4])[0]:08X}"
    return f"{name} ({len(body)}B)"

# ── 握手流程 ─────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="PTP-IP 真机验证(尼康 Z 系列)")
    ap.add_argument("host", nargs="?", default="192.168.1.1", help="相机 IP,默认 192.168.1.1")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--hostname", default="probe-host", help="InitCommandReq 中的主机名")
    args = ap.parse_args()

    # 步骤 1:command 通道 TCP 连接
    cmd = socket.create_connection((args.host, args.port), timeout=5)
    print(f"[1] TCP 已连接 {args.host}:{args.port}(command 通道)")

    # 步骤 2:Init Command Request,读响应
    cmd.sendall(init_command_request(args.hostname))
    ptype, body = read_packet(cmd)
    print(f"[2] <- {describe(ptype, body)}")
    if ptype == INIT_FAIL:
        print("    InitFail:检查主机名编码(UTF-16LE)与长度字段(u32)")
        return 1
    if ptype != INIT_CMD_RESP:
        print(f"    意外包类型 {ptype},期望 {INIT_CMD_RESP}")
        return 1
    connection_number = struct.unpack("<I", body[:4])[0]

    # TODO(P0) 步骤 3:独立 event socket 连 15740,发送 init_event_request(connection_number),
    #   期望 INIT_EVENT_RESP(4)—— InitEventRequest 必须发在独立 event socket 上。
    # TODO(P0) 步骤 4:OpenSession(0x1002, DataPhaseInfo=无数据, sessionId=1),
    #   期望 OP_RESP 响应码 0x2001(OK)。
    # TODO(P0) 步骤 5:GetObjectHandles(0x1007, storage=0xFFFFFFFF, format=0, parent=0xFFFFFFFF),
    #   数据相为 StartData(u64 总长)/Data/EndData 循环,解析对象数与 handle 数组。
    # TODO(P0) 步骤 6:核对 DataPhaseInfo 三个取值的真实语义、NEF 的 ObjectFormatCode,
    #   结论回填 lib/core/ptpip/operation_codes.dart 与 object_format.dart。

    cmd.close()
    print("[OK] command 通道握手通过;后续步骤见文件内 TODO(P0) 标记")
    return 0


if __name__ == "__main__":
    sys.exit(main())
