#!/usr/bin/env python3
"""Generate one WhalePet utterance with edge-tts.

The helper has no direct dependencies beyond edge-tts, which is installed in an
external venv.  It exits non-zero with a concise diagnostic so Swift can fall
back to AVSpeechSynthesizer.
"""

import argparse
import asyncio
import glob
import os
import site
import sys
import tempfile


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
            raise RuntimeError(
                "edge-tts 未安装；请设置 TTS_VENV 或在 /tmp/ttsvenv 中安装"
            ) from exc


def parse_args():
    parser = argparse.ArgumentParser(description="WhalePet edge-tts helper")
    parser.add_argument("--text", required=True)
    parser.add_argument("--voice", default="zh-CN-XiaoyiNeural")
    parser.add_argument("--rate", default="+0%")
    parser.add_argument("--pitch", default="+0Hz")
    parser.add_argument("--volume", default="+0%")
    # Kept only for forward compatibility. Current edge-tts does not support it.
    parser.add_argument("--style", default=None)
    parser.add_argument("--output", default="/tmp/whalepet_tts.mp3")
    return parser.parse_args()


async def generate(args):
    edge_tts = load_edge_tts()
    directory = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".whalepet_tts_", suffix=".mp3", dir=directory)
    os.close(fd)
    try:
        communicate = edge_tts.Communicate(
            args.text,
            voice=args.voice,
            rate=args.rate,
            pitch=args.pitch,
            volume=args.volume,
        )
        await communicate.save(temporary)
        if os.path.getsize(temporary) == 0:
            raise RuntimeError("edge-tts 返回了空音频")
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    try:
        args = parse_args()
        if not args.text.strip():
            raise RuntimeError("文本为空")
        asyncio.run(generate(args))
    except Exception as exc:
        print(f"WhalePet TTS 失败: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
