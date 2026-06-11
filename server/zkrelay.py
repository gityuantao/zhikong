#!/usr/bin/env python3
"""
直控 WAN 中转 relay —— 跑在公网 VPS 上,把两台 Mac(Host 被控 / Client 远控)按房间号配对、
字节级双向转发。两端都【出站】连本服务器,故不惧家里双层 NAT + 无公网(出站连接天然穿透 NAT)。

适配用户实际网络:P2P 直连打不通 → 本就得中转 → 直接中转,比 WebRTC+coturn 简单一个数量级,
且 Host/Client 的封包/分帧(VideoFramePacket/AudioPacket/InputEvent/StreamFramer)一行不用改,
原样穿过本中转。

协议:连上后先发一行 ASCII 握手 `ZKRELAY <HOST|CLIENT> <ROOM>\n`,之后即原始字节流双向转发。
房间号 ROOM 同时充当"共享口令"(只有知道 ROOM 的两端才会被配上)。

实时策略:某端没有对端在场时,其数据直接丢弃(实时流不缓存旧帧)。

⚠️ 安全(MVP→正式前必做):本中转**明文转发**。ROOM 提供基础准入,但链路未加密——
正式使用前要么在 Host/Client 间走端到端 TLS(经本中转透传),要么至少逐跳 TLS 到本服务器。
当前明文仅用于打通验证,别用它传敏感屏幕内容。

用法:python3 zkrelay.py [PORT]   (默认 7777;记得在主机商安全组放行该 TCP 端口)
"""
import asyncio
import logging
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
HANDSHAKE_TIMEOUT = 15
CHUNK = 65536
# 视频向:对端写缓冲超此阈值=消费者跟不上(窄链路)→ 丢帧,保实时、防反压把上游也堵断。
DROP_THRESHOLD = 1024 * 1024  # 1MB

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("zkrelay")

# room -> { "HOST": writer_or_None, "CLIENT": writer_or_None }
# (不用 PEP585/604 类型注解,兼容 VPS 上较老的 Python 3.7+)
peers = {}


def presence_frame(present):
    """中转控制帧:告知对端在不在线。线格式 = 4 字节大端长度(5) + b'ZKRL' + present(1)。"""
    return (5).to_bytes(4, "big") + b"ZKRL" + (b"\x01" if present else b"\x00")


def _notify(writer, present):
    if writer is None:
        return
    try:
        writer.write(presence_frame(present))
    except Exception:
        pass


async def handle(reader, writer):
    addr = writer.get_extra_info("peername")
    # 1) 握手行
    try:
        line = await asyncio.wait_for(reader.readline(), timeout=HANDSHAKE_TIMEOUT)
    except (asyncio.TimeoutError, ConnectionError):
        writer.close()
        return
    parts = line.decode("ascii", "ignore").strip().split()
    if len(parts) != 3 or parts[0] != "ZKRELAY" or parts[1] not in ("HOST", "CLIENT"):
        log.info("拒绝 %s:握手非法 %r", addr, line[:64])
        writer.close()
        return
    role, room = parts[1], parts[2]
    other = "CLIENT" if role == "HOST" else "HOST"

    slot = peers.setdefault(room, {"HOST": None, "CLIENT": None})
    # 同角色重连:踢掉旧连接
    if slot[role] is not None:
        try:
            slot[role].close()
        except Exception:
            pass
    slot[role] = writer
    peer = slot[other]
    log.info("%s 加入 room=%s（%s）；对端%s", role, room, addr, "在场" if peer else "未到")
    # 在线状态:告诉自己对端在不在,并告诉对端"我来了"。
    _notify(writer, peer is not None)
    _notify(peer, True)

    # 2) 持续读本端,按【4 字节大端长度前缀】切出完整帧,只转发完整帧。
    #    关键:字节级转发会让"中途加入的一方"从某帧中间收起 → 分帧器永久错位 → 黑屏。
    #    按帧边界转发,则任何时刻加入的对端都从帧边界对齐。无对端时整帧丢弃(实时流)。
    buf = bytearray()
    MAX_FRAME = 16 * 1024 * 1024  # 安全上限,防错位/垃圾长度撑爆内存
    try:
        while True:
            data = await reader.read(CHUNK)
            if not data:
                break
            buf.extend(data)
            while len(buf) >= 4:
                flen = int.from_bytes(buf[0:4], "big")
                if flen > MAX_FRAME:
                    log.info("%s room=%s 帧长异常 %d → 断开", role, room, flen)
                    raise ConnectionError("bad frame length")
                total = 4 + flen
                if len(buf) < total:
                    break  # 半帧,留待下次补齐
                frame = bytes(buf[0:total])
                del buf[0:total]
                dst = peers.get(room, {}).get(other)
                if dst is not None:
                    if role == "HOST":
                        # 视频向(Host→Client):慢链路丢帧不阻塞;写缓冲未堆积才发,堆了就丢本帧。
                        tr = dst.transport
                        if tr is None or tr.get_write_buffer_size() < DROP_THRESHOLD:
                            dst.write(frame)
                    else:
                        # 输入向(Client→Host):低频且不可丢,正常写+背压。
                        dst.write(frame)
                        await dst.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        # 仅当槽位仍是自己时才清空(避免误清掉替换进来的新连接)
        cur = peers.get(room, {})
        if cur.get(role) is writer:
            cur[role] = None
            _notify(cur.get(other), False)   # 告诉对端"我走了"
            if cur.get("HOST") is None and cur.get("CLIENT") is None:
                peers.pop(room, None)
        try:
            writer.close()
        except Exception:
            pass
        log.info("%s 离开 room=%s", role, room)


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    log.info("直控中转已启动,监听 0.0.0.0:%d", PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
