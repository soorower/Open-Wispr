#!/usr/bin/env python3
"""Standalone check of the live streaming path, no mic needed.

Speaks the exact same protocol LiveTranscribe.swift does — same URL, same
session.update shape, same event names — so if this prints a transcript the app
will too. Synthesizes a sentence with `say`, streams it as 24 kHz PCM16 in
real time, and prints the deltas as they arrive.

    ./test_live.py                 # key from OPENAI_API_KEY or ~/.config/openwispr/.env
    ./test_live.py gpt-4o-transcribe

Needs: pip3 install websockets
"""
import asyncio
import base64
import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path

import websockets

URL = "wss://api.openai.com/v1/realtime?intent=transcription"
RATE = 24000
CHUNK_MS = 40                      # what a real mic tap delivers, roughly
ENV = Path.home() / ".config/openwispr/.env"


def api_key() -> str:
    key = os.environ.get("OPENAI_API_KEY", "")
    if not key and ENV.exists():
        for line in ENV.read_text().splitlines():
            if line.startswith("OPENAI_API_KEY="):
                key = line.split("=", 1)[1].strip()
    if not key:
        sys.exit("No key. Export OPENAI_API_KEY or add it to ~/.config/openwispr/.env")
    return key


def spoken_pcm(text: str) -> bytes:
    """`say` -> 24 kHz mono PCM16, the format the realtime session expects."""
    tmp = Path(os.environ.get("TMPDIR", "/tmp"))
    aiff, wav = tmp / "openwispr_live.aiff", tmp / "openwispr_live.wav"
    subprocess.run(["say", "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1",
                    str(aiff), str(wav)], check=True)
    with wave.open(str(wav)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (RATE, 1, 2), \
            "afconvert didn't produce 24 kHz mono PCM16"
        return w.readframes(w.getnframes())


async def connect(key: str):
    headers = {"Authorization": f"Bearer {key}"}
    try:                                     # websockets >= 13 asyncio client
        return await websockets.connect(URL, additional_headers=headers)
    except TypeError:                        # older legacy client
        return await websockets.connect(URL, extra_headers=headers)


def session_update(model: str, vad: bool) -> str:
    turn = ({"type": "server_vad", "threshold": 0.5,
             "prefix_padding_ms": 300, "silence_duration_ms": 400} if vad else None)
    return json.dumps({
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {"input": {
                "format": {"type": "audio/pcm", "rate": RATE},
                "transcription": {"model": model},
                "turn_detection": turn,
            }},
        },
    })


async def main() -> int:
    model = sys.argv[1] if len(sys.argv) > 1 else "gpt-live-transcribe"
    sentence = "Hello, this is an Open Wispr live transcription test. One two three."
    print(f"Model: {model}")

    pcm = spoken_pcm(sentence)
    print(f"Audio: {len(pcm) / 2 / RATE:.1f}s of {RATE} Hz PCM16")

    ws = await connect(api_key())
    print(f"Connected to {URL}")

    # gpt-live-transcribe refuses turn detection outright ("Turn detection is not
    # supported for this transcription model"), and deltas stream without it, so
    # null is the right default. The retry below is kept for other models.
    vad = False
    ready = asyncio.Event()
    finals, deltas, failed = {}, {}, []
    first_delta_at = None
    started = time.monotonic()

    async def reader():
        nonlocal vad, first_delta_at
        async for raw in ws:
            event = json.loads(raw)
            kind = event.get("type", "")
            if kind in ("session.created", "transcription_session.created"):
                await ws.send(session_update(model, vad))
            elif kind in ("session.updated", "transcription_session.updated"):
                if not ready.is_set():
                    print(f"Session configured (server_vad={vad})")
                    ready.set()
            elif kind.endswith("input_audio_transcription.delta"):
                if first_delta_at is None:
                    first_delta_at = time.monotonic() - started
                    print(f"First delta after {first_delta_at:.2f}s\n")
                deltas[event.get("item_id")] = deltas.get(event.get("item_id"), "") + event.get("delta", "")
                print(f"  delta: {event.get('delta')!r}", flush=True)
            elif kind.endswith("input_audio_transcription.completed"):
                finals[event.get("item_id")] = event.get("transcript", "")
                print(f"  DONE:  {event.get('transcript')!r}", flush=True)
            elif kind.endswith("input_audio_transcription.failed"):
                failed.append(str(event.get("error")))
            elif kind == "error":
                message = (event.get("error") or {}).get("message", raw)
                if not ready.is_set() and vad:
                    # Same fallback the app has: retry with the plainest shape.
                    print(f"!! session.update rejected: {message}\n   retrying without server VAD")
                    vad = False
                    await ws.send(session_update(model, vad))
                else:
                    failed.append(message)
                    return

    task = asyncio.create_task(reader())
    try:
        await asyncio.wait_for(ready.wait(), timeout=15)
    except asyncio.TimeoutError:
        print("!! session never configured", *failed, sep="\n")
        return 1

    step = int(RATE * CHUNK_MS / 1000) * 2
    for i in range(0, len(pcm), step):
        await ws.send(json.dumps({"type": "input_audio_buffer.append",
                                  "audio": base64.b64encode(pcm[i:i + step]).decode()}))
        await asyncio.sleep(CHUNK_MS / 1000)      # pace it like a live mic

    if vad:
        silence = b"\x00" * int(RATE * 2 * 0.6)   # let VAD hear the end of speech
        await ws.send(json.dumps({"type": "input_audio_buffer.append",
                                  "audio": base64.b64encode(silence).decode()}))
    else:
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

    for _ in range(40):                            # up to 4s of grace
        await asyncio.sleep(0.1)
        if finals and not deltas.keys() - finals.keys():
            break

    task.cancel()
    await ws.close()

    text = " ".join(finals.get(k) or deltas.get(k, "") for k in (finals | deltas)).strip()
    print("\n" + "-" * 60)
    if failed:
        print("ERRORS:", *failed, sep="\n  ")
    print(f"SAID:       {sentence}")
    print(f"TRANSCRIPT: {text or '(nothing)'}")
    if first_delta_at:
        print(f"first delta {first_delta_at:.2f}s after connect · server_vad={vad}")
    return 0 if text and not failed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
