"""YuE2 (experimental) through audio.cpp's command-line runner.

install-yue2.bat puts the audio.cpp Windows CUDA build in runtime/audio.cpp
and the GGUF package in runtime/models/Yue2-3B-GGUF. Each song is one
audiocpp_cli run; ACE-Step is stopped first so YuE2 gets the whole GPU.

YuE2-3B is licensed CC BY-NC 4.0 (non-commercial).
"""

from __future__ import annotations

import asyncio
import os
import time
from collections import deque
from pathlib import Path
from typing import Optional

from . import config

AUDIOCPP_DIR = config.RUNTIME / "audio.cpp"
MODEL_DIR = config.RUNTIME / "models" / "Yue2-3B-GGUF"
EXE = "audiocpp_cli.exe" if config.IS_WINDOWS else "audiocpp_cli"

# Main model sizes in preference order (q8_0 fits a 12 GB card; q4_0 for 8 GB).
MAIN_GGUFS = ("yue2-3b-q8_0.gguf", "yue2-3b-q4_0.gguf", "yue2-3b-bf16.gguf")
VAE_GGUF = "yue2-vae-f16.gguf"
COT_MODES = ("off", "melody", "full")


def cli_path() -> Optional[Path]:
    if not AUDIOCPP_DIR.exists():
        return None
    for p in AUDIOCPP_DIR.rglob(EXE):
        return p
    return None


def main_gguf() -> Optional[str]:
    for name in MAIN_GGUFS:
        if (MODEL_DIR / name).exists():
            return name
    return None


def status() -> dict:
    cli, gguf = cli_path(), main_gguf()
    ready = bool(cli and gguf and (MODEL_DIR / VAE_GGUF).exists() and (MODEL_DIR / "sidecars").exists())
    reason = ""
    if not cli:
        reason = "audio.cpp is not installed. Run install-yue2.bat on the PC."
    elif not ready:
        reason = "YuE2 model files are missing. Run install-yue2.bat on the PC."
    return {"ready": ready, "reason": reason, "model": gguf or "", "experimental": True}


def request_options(sound: dict) -> list[str]:
    """Map the app's 0..1 sliders onto YuE2 sampling options.
    0.5 keeps the upstream defaults (semantic temperature 1.0, top-p 0.95)."""
    s = sound or {}
    w = min(1.0, max(0.0, float(s.get("weirdness", 0.5))))
    si = min(1.0, max(0.0, float(s.get("style_influence", 0.5))))
    opts = []
    if abs(w - 0.5) > 1e-3:
        opts += [f"semantic_temperature={0.7 + 0.6 * w:.3f}", f"semantic_top_p={min(0.99, 0.9 + 0.1 * w):.3f}"]
    if abs(si - 0.5) > 1e-3:
        opts.append(f"guidance_scale={max(1.0, 1.01 + (si - 0.5) * 3.0):.3f}")
    steps = {"fast": 6, "high": 16}.get(s.get("quality", "standard"), 8)
    opts.append(f"num_inference_steps={steps}")
    return opts


class Yue2Runner:
    def __init__(self) -> None:
        self.log: deque[str] = deque(maxlen=2000)
        self.active_since = 0.0
        self.proc: Optional[asyncio.subprocess.Process] = None

    def lines(self, tail: int = 200) -> list[str]:
        return list(self.log)[-tail:]

    @property
    def recently_active(self) -> bool:
        return self.proc is not None or time.time() - self.active_since < 600

    async def run(self, *, style: str, lyrics: str, cot: str, seed: int, sound: dict, out: Path,
                  on_line=None) -> int:
        st = status()
        if not st["ready"]:
            raise RuntimeError(st["reason"])
        cli = cli_path()
        cot = cot if cot in COT_MODES else "off"
        out.parent.mkdir(parents=True, exist_ok=True)
        if seed < 0:
            seed = int.from_bytes(os.urandom(4), "little") & 0x7FFFFFFF
        env = dict(os.environ)
        if not config.IS_WINDOWS:   # cudart from the release lives next to the binary
            env["LD_LIBRARY_PATH"] = os.pathsep.join(
                [str(p.parent) for p in AUDIOCPP_DIR.rglob("libcudart*")] + [env.get("LD_LIBRARY_PATH", "")])
        args = [
            str(cli), "--task", "gen", "--family", "yue2",
            "--model", str(MODEL_DIR),
            "--backend", "cuda", "--threads", str(max(2, (os.cpu_count() or 8) // 2)),
            "--session-option", f"yue2.model_gguf={st['model']}",
            "--session-option", f"yue2.vae_gguf={VAE_GGUF}",
            "--lyrics", lyrics or "[instrumental]",
            "--request-option", f"style={style}",
            "--request-option", f"cot={cot}",
            "--seed", str(seed),
            "--out", str(out),
            "--log",
        ]
        for o in request_options(sound):
            args += ["--request-option", o]
        self.log.append("$ " + " ".join(a if " " not in a else f'"{a[:60]}..."' for a in args))
        self.active_since = time.time()
        self.proc = await asyncio.create_subprocess_exec(
            *args, cwd=str(cli.parent), env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        try:
            assert self.proc.stdout is not None
            async for raw in self.proc.stdout:
                line = raw.decode("utf-8", "replace").rstrip()
                if line:
                    self.log.append(line)
                    if on_line:
                        on_line(line)
            code = await self.proc.wait()
        finally:
            self.proc = None
            self.active_since = time.time()
        if code != 0 or not out.exists():
            tail = next((l for l in reversed(self.log) if "error" in l.lower() or "assert" in l.lower()), "")
            raise RuntimeError(f"YuE2 failed (exit {code}). {tail}".strip())
        return seed

    async def cancel(self) -> None:
        if self.proc and self.proc.returncode is None:
            self.proc.kill()


runner = Yue2Runner()
