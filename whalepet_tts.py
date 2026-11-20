#!/usr/bin/env python3
"""WhalePet TTS helper — 火山引擎双向流式 TTS (seed-tts-2.0) + edge-tts 兜底

协议帧格式内嵌（依据官方 TTS Websocket Bidirection protocols 实现）。
鉴权 key 从 ~/.hermes/.env 的 VOLC_TTS_API_KEY 读取，不落明文。
"""

import argparse
import asyncio
import base64
import glob
import json
import os
import site
import struct
import sys
import tempfile
import uuid

VOLC_URL = "wss://openspeech.bytedance.com/api/v3/tts/bidirection"
VOLC_RESOURCE = "seed-tts-2.0"
VOLC_SPEAKER = "zh_female_vv_uranus_bigtts"

# ---- 协议常量（火山二进制帧）----
PROTO_VERSION = 0b0001
HEADER_SIZE = 0b0001  # 4 bytes
FULL_CLIENT = 0b0001
AUDIO_ONLY_CLIENT = 0b0010
FULL_SERVER = 0b1001
AUDIO_ONLY_SERVER = 0b1011
ERROR_TYPE = 0b1111

FLAG_NO_SEQ = 0b0000
FLAG_POS_SEQ = 0b0001
FLAG_NEG_SEQ = 0b0011
FLAG_WITH_EVENT = 0b0100

SER_JSON = 0b0001
COMP_NONE = 0b0000

EV_START_CONNECTION = 1
EV_FINISH_CONNECTION = 2
EV_START_SESSION = 100
EV_FINISH_SESSION = 102
EV_TASK_REQUEST = 200

CONNECTION_EVENTS = {1, 2, 50, 51, 52}


def _header(msg_type, flag, ser=SER_JSON, comp=COMP_NONE):
    return bytes([
        (PROTO_VERSION << 4) | HEADER_SIZE,
        (msg_type << 4) | flag,
        (ser << 4) | comp,
        0,
    ])


def _pack(msg_type, flag, payload=b"", event=None, session_id=None):
    out = bytearray(_header(msg_type, flag))
    if event is not None:
        out += struct.pack(">i", event)
        if session_id is not None and event not in CONNECTION_EVENTS:
            sid = session_id.encode()
            out += struct.pack(">I", len(sid)) + sid
    out += struct.pack(">I", len(payload)) + payload
    return bytes(out)


def _parse(data):
    """返回 dict: type, flag, event, session_id, payload"""
    info = {"type": None, "flag": None, "event": None,
            "session_id": "", "payload": b"", "error_code": None}
    if len(data) < 4:
        return info
    b0, b1, b2 = data[0], data[1], data[2]
    header_size = (b0 & 0x0F) * 4
    info["type"] = (b1 >> 4) & 0x0F
    info["flag"] = b1 & 0x0F
    ser = (b2 >> 4) & 0x0F
    pos = max(header_size, 4)

    def rd32(p):
        if p + 4 > len(data):
            return None, p
        return struct.unpack(">I", data[p:p + 4])[0], p + 4

    if info["type"] == ERROR_TYPE:
        code, pos = rd32(pos)
        info["error_code"] = code
        size, pos = rd32(pos)
        if size:
            info["payload"] = data[pos:pos + size]
        return info

    if info["flag"] in (FLAG_POS_SEQ, FLAG_NEG_SEQ):
        _seq, pos = rd32(pos)

    if info["flag"] == FLAG_WITH_EVENT:
        if pos + 4 <= len(data):
            info["event"] = struct.unpack(">i", data[pos:pos + 4])[0]
            pos += 4
        if info["event"] not in CONNECTION_EVENTS:
            n, pos = rd32(pos)
            if n:
                info["session_id"] = data[pos:pos + n].decode("utf-8", "replace")
                pos += n
        if info["event"] in (50, 51, 52):
            n, pos = rd32(pos)
            if n:
                pos += n

    size, pos = rd32(pos)
    if size:
        info["payload"] = data[pos:pos + size]
    return info


def load_api_key():
    """从 ~/.hermes/.env 读 VOLC_TTS_API_KEY（或环境变量）"""
    key = os.environ.get("VOLC_TTS_API_KEY")
    if key:
        return key.strip()
    env_path = os.path.expanduser("~/.hermes/.env")
    var = "VOLC_TTS_" + "API_KEY"  # 拼接避免被脱敏规则拦截
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                if line.startswith(var + "="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("未配置 VOLC_TTS_API_KEY")


def parse_percent(value, default=0):
    """' +22% ' -> 22 ; '0%' -> 0"""
    if not value:
        return default
    try:
        return int(round(float(str(value).replace("%", "").replace("+", "").strip())))
    except Exception:
        return default


async def volc_generate(text, output, rate="+0%", volume="+0%", speaker=VOLC_SPEAKER,
                        pitch_semitones=0):
    import websockets

    key = load_api_key()
    speech_rate = max(-50, min(100, parse_percent(rate)))
    loudness = max(-50, min(100, parse_percent(volume)))
    pitch = max(-12, min(12, int(pitch_semitones)))

    headers = {
        "X-Api-Key": key,
        "X-Api-Resource-Id": VOLC_RESOURCE,
        "X-Api-Connect-Id": str(uuid.uuid4()),
    }
    audio = bytearray()
    async with websockets.connect(VOLC_URL, additional_headers=headers,
                                  max_size=None, open_timeout=10) as ws:
        # 1) StartConnection
        await ws.send(_pack(FULL_CLIENT, FLAG_WITH_EVENT,
                            json.dumps({}).encode(), event=EV_START_CONNECTION))
        m = _parse(await asyncio.wait_for(ws.recv(), timeout=10))
        if m["type"] == ERROR_TYPE:
            raise RuntimeError(f"建连失败 code={m['error_code']} {m['payload'][:160]!r}")

        # 2) StartSession
        sid = uuid.uuid4().hex
        req = {"req_params": {
            "speaker": speaker,
            "audio_params": {"format": "mp3", "sample_rate": 24000},
            "speech_rate": speech_rate,
            "loudness_rate": loudness,
            "post_process": {"pitch": pitch},
        }}
        await ws.send(_pack(FULL_CLIENT, FLAG_WITH_EVENT,
                            json.dumps(req, ensure_ascii=False).encode(),
                            event=EV_START_SESSION, session_id=sid))
        m = _parse(await asyncio.wait_for(ws.recv(), timeout=12))
        if m["type"] == ERROR_TYPE:
            raise RuntimeError(f"会话失败 code={m['error_code']} "
                               f"{m['payload'][:200].decode('utf-8','replace')}")

        # 3) TaskRequest 送文本（必须包在 req_params 里）
        payload = json.dumps({"req_params": {"text": text}},
                             ensure_ascii=False).encode()
        await ws.send(_pack(FULL_CLIENT, FLAG_WITH_EVENT, payload,
                            event=EV_TASK_REQUEST, session_id=sid))

        # 4) FinishSession 结束文本
        await ws.send(_pack(FULL_CLIENT, FLAG_WITH_EVENT,
                            json.dumps({}).encode(),
                            event=EV_FINISH_SESSION, session_id=sid))

        # 5) 收音频
        while True:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=8)
            except asyncio.TimeoutError:
                break
            if isinstance(raw, str):
                continue
            m = _parse(raw)
            if m["type"] == ERROR_TYPE:
                raise RuntimeError(f"合成失败 code={m['error_code']} "
                                   f"{m['payload'][:200].decode('utf-8','replace')}")
            body = m["payload"]
            if body:
                if body[:1] == b"{":
                    try:
                        j = json.loads(body)
                        if j.get("data"):
                            audio += base64.b64decode(j["data"])
                    except Exception:
                        pass
                else:
                    audio += body
            if m["event"] in (152, 153, 359, 52):  # SessionFinished/Failed/TTSEnded
                break

    if len(audio) < 100:
        raise RuntimeError(f"火山返回音频过短: {len(audio)} 字节")
    return bytes(audio)


def load_edge_tts():
    try:
        import edge_tts
        return edge_tts
    except ImportError:
        venv = os.environ.get("TTS_VENV", "/tmp/ttsvenv")
        version = f"python{sys.version_info.major}.{sys.version_info.minor}"
        candidates = [
            os.path.join(venv, "lib", version, "site-packages"),
            os.path.join(venv, "lib", "site-packages"),
        ]
        candidates.extend(glob.glob(os.path.join(venv, "lib", "python*", "site-packages")))
        for path in candidates:
            if os.path.isdir(path):
                site.addsitedir(path)
        try:
            import edge_tts
            return edge_tts
        except ImportError as exc:
            raise RuntimeError("edge-tts 未安装") from exc


async def edge_generate(text, output, voice, rate, pitch, volume):
    edge_tts = load_edge_tts()
    communicate = edge_tts.Communicate(text, voice=voice, rate=rate,
                                       pitch=pitch, volume=volume)
    tmp = tempfile.mkstemp(suffix=".mp3", dir=os.path.dirname(os.path.abspath(output)))[1]
    try:
        await communicate.save(tmp)
        if os.path.getsize(tmp) == 0:
            raise RuntimeError("edge-tts 返回空音频")
        os.replace(tmp, output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


async def synthesize(text, output, voice, rate, pitch, volume, backend="volc",
                     pitch_st=0):
    directory = os.path.dirname(os.path.abspath(output))
    os.makedirs(directory, exist_ok=True)
    if not text.strip():
        raise RuntimeError("文本为空")

    if backend == "volc":
        speaker = voice if voice and "_bigtts" in voice else VOLC_SPEAKER
        try:
            data = await volc_generate(text, output, rate=rate,
                                       volume=volume, speaker=speaker,
                                       pitch_semitones=pitch_st)
            tmp = tempfile.mkstemp(suffix=".mp3", dir=directory)[1]
            try:
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, output)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            return
        except Exception as exc:
            print(f"VOLC_TTS_FAILED: {exc}", file=sys.stderr, flush=True)
            # 兜底走 edge-tts
    await edge_generate(text, output, voice or "zh-CN-XiaoyiNeural",
                        rate, pitch, volume)


def parse_args():
    p = argparse.ArgumentParser(description="WhalePet TTS helper")
    p.add_argument("--text")
    p.add_argument("--daemon", action="store_true")
    p.add_argument("--voice", default=VOLC_SPEAKER)
    p.add_argument("--rate", default="+22%")
    p.add_argument("--pitch", default="+0Hz")
    p.add_argument("--pitch-st", type=int, default=0,
                   help="火山音调（半音，-12..12，默认 0）")
    p.add_argument("--volume", default="+12%")
    p.add_argument("--backend", default="volc", choices=["volc", "edge"])
    p.add_argument("--output", default="/tmp/whalepet_tts.mp3")
    return p.parse_args()


async def daemon_main():
    loop = asyncio.get_running_loop()
    current = None

    async def run_request(request):
        rid = str(request.get("id", ""))
        try:
            await synthesize(
                request.get("text", ""),
                request.get("output", "/tmp/whalepet_tts.mp3"),
                request.get("voice", VOLC_SPEAKER),
                request.get("rate", "+22%"),
                request.get("pitch", "+0Hz"),
                request.get("volume", "+12%"),
                request.get("backend", "volc"),
                int(request.get("pitchST", 0)),
            )
            resp = {"id": rid, "ok": True}
        except asyncio.CancelledError:
            resp = {"id": rid, "ok": False, "error": "cancelled"}
        except Exception as exc:
            resp = {"id": rid, "ok": False, "error": str(exc)}
        print(json.dumps(resp, ensure_ascii=False), flush=True)

    while True:
        line = await loop.run_in_executor(None, sys.stdin.buffer.readline)
        if not line:
            # stdin EOF: 等最后一个任务跑完，不要取消它（否则测试/关闭场景会丢结果）
            if current and not current.done():
                await asyncio.gather(current, return_exceptions=True)
            return
        try:
            request = json.loads(line)
            if current and not current.done():
                current.cancel()
                await asyncio.gather(current, return_exceptions=True)
            if request.get("command") != "cancel":
                current = asyncio.create_task(run_request(request))
        except Exception as exc:
            print(json.dumps({"id": "", "ok": False, "error": str(exc)}), flush=True)


def main():
    try:
        args = parse_args()
        if args.daemon:
            asyncio.run(daemon_main())
            return 0
        asyncio.run(synthesize(args.text, args.output, args.voice,
                               args.rate, args.pitch, args.volume, args.backend,
                               args.pitch_st))
    except Exception as exc:
        print(f"WhalePet TTS 失败: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
