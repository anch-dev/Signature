"""Runs at most one GPU-heavy program at a time.

Modes:
  idle      nothing loaded, GPU free
  api       ACE-Step REST API (phone generation + LoRA styles)      127.0.0.1:8001
  studio    ACE-Step Studio web GUI (+ its built-in API)            0.0.0.0:7860
  training  Side-Step jobs own the GPU (see training.py)

A 12 GB card can't hold the Studio, the API and a training run at once, so
switching modes stops whatever was running first.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import threading
import time
from collections import deque
from typing import Optional

import httpx
import psutil

from . import config

MODES = ("idle", "api", "studio", "training")


class ManagedProcess:
    def __init__(self, name: str, cmd: list[str], cwd, env: Optional[dict] = None, log_lines: int = 3000):
        self.name = name
        self.cmd = cmd
        self.cwd = str(cwd)
        self.env = {**os.environ, "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8", **(env or {})}
        self.log: deque[str] = deque(maxlen=log_lines)
        self.proc: Optional[subprocess.Popen] = None
        self.started_at = 0.0

    def start(self) -> None:
        self.log.append(f"$ {' '.join(self.cmd)}")
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if config.IS_WINDOWS else 0
        self.proc = subprocess.Popen(
            self.cmd, cwd=self.cwd, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            creationflags=flags, bufsize=1, text=True, encoding="utf-8", errors="replace",
        )
        self.started_at = time.time()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.proc and self.proc.stdout
        buf = ""
        while True:
            ch = self.proc.stdout.read(1)
            if not ch:
                break
            # tqdm progress bars rewrite the line with \r; keep only the latest.
            if ch == "\r":
                if buf:
                    self._push(buf, replace=True)
                buf = ""
            elif ch == "\n":
                self._push(buf, replace=bool(self.log) and self.log[-1].startswith("\x00"))
                buf = ""
            else:
                buf += ch
        if buf:
            self._push(buf)
        code = self.proc.wait()
        self.log.append(f"[{self.name} exited with code {code}]")

    def _push(self, line: str, replace: bool = False) -> None:
        line = line.rstrip()
        if replace and self.log and self.log[-1].startswith("\x00"):
            self.log[-1] = "\x00" + line
        elif replace:
            self.log.append("\x00" + line)
        else:
            if self.log and self.log[-1].startswith("\x00"):
                self.log[-1] = self.log[-1][1:]
            self.log.append(line)

    def lines(self, tail: int = 200) -> list[str]:
        return [l.lstrip("\x00") for l in list(self.log)[-tail:]]

    @property
    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    @property
    def exit_code(self) -> Optional[int]:
        return None if self.proc is None else self.proc.poll()

    def stop(self, timeout: float = 15) -> None:
        if not self.alive:
            return
        try:
            parent = psutil.Process(self.proc.pid)
            procs = parent.children(recursive=True) + [parent]
        except psutil.NoSuchProcess:
            return
        for p in procs:
            try:
                p.terminate()
            except psutil.NoSuchProcess:
                pass
        _, alive = psutil.wait_procs(procs, timeout=timeout)
        for p in alive:
            try:
                p.kill()
            except psutil.NoSuchProcess:
                pass


class Supervisor:
    def __init__(self, settings: config.Settings):
        self.settings = settings
        self.mode = "idle"
        self.state = "stopped"   # stopped | starting | ready | error
        self.error: Optional[str] = None
        self.proc: Optional[ManagedProcess] = None
        self.last_logs: dict[str, ManagedProcess] = {}
        self._lock = asyncio.Lock()

    # ---- commands -------------------------------------------------------
    def _api_cmd(self) -> ManagedProcess:
        uv = config.uv_exe()
        return ManagedProcess(
            "api",
            [uv, "run", "acestep-api", "--host", "127.0.0.1", "--port", str(config.API_PORT),
             "--api-key", self.settings.internal_key, "--lm-model-path", config.LM_MODEL],
            cwd=config.ACESTEP_DIR,
            env={"ACESTEP_CONFIG_PATH": config.DIT_MODEL, "ACESTEP_INIT_LLM": "auto",
                 "ACESTEP_LM_MODEL_PATH": config.LM_MODEL},
        )

    def _studio_cmd(self) -> ManagedProcess:
        uv = config.uv_exe()
        return ManagedProcess(
            "studio",
            [uv, "run", "acestep", "--port", str(config.STUDIO_PORT), "--server-name", "0.0.0.0",
             "--config_path", config.DIT_MODEL, "--lm_model_path", config.LM_MODEL,
             "--init_service", "true", "--language", "en",
             "--enable-api", "--api-key", self.settings.internal_key,
             # Studio is reachable from the phone's browser, so it needs a login.
             "--auth-username", "signature", "--auth-password", self.settings.token],
            cwd=config.ACESTEP_DIR,
        )

    @property
    def base_url(self) -> Optional[str]:
        if self.mode == "api":
            return f"http://127.0.0.1:{config.API_PORT}"
        if self.mode == "studio":
            return f"http://127.0.0.1:{config.STUDIO_PORT}"
        return None

    # ---- switching ------------------------------------------------------
    async def switch(self, mode: str, wait: bool = True) -> None:
        if mode not in MODES:
            raise ValueError(f"unknown mode {mode}")
        async with self._lock:
            already = mode == self.mode and (mode in ("idle", "training") or (self.proc and self.proc.alive))
            if not already:
                await self._start_locked(mode)
        if self.state == "starting":
            if wait:
                await self.wait_ready()
            else:
                asyncio.create_task(self.wait_ready())

    async def _start_locked(self, mode: str) -> None:
        await asyncio.to_thread(self._stop_current)
        self.mode = mode
        self.error = None
        if mode in ("idle", "training"):
            self.state = "ready" if mode == "training" else "stopped"
            return
        if not config.ACESTEP_DIR.exists():
            self.state = "error"
            self.error = "ACE-Step is not installed. Run install.bat."
            return
        self.proc = self._api_cmd() if mode == "api" else self._studio_cmd()
        self.last_logs["acestep"] = self.proc
        self.proc.start()
        self.state = "starting"

    def _stop_current(self) -> None:
        if self.proc:
            self.proc.stop()
        self.proc = None
        self.state = "stopped"

    async def wait_ready(self, timeout: float = 1800) -> bool:
        """First start can take a long time (model download + load)."""
        deadline = time.time() + timeout
        url = self.base_url
        headers = {"Authorization": f"Bearer {self.settings.internal_key}"}
        async with httpx.AsyncClient(timeout=5) as client:
            while time.time() < deadline:
                if self.state != "starting":
                    return self.state == "ready"
                if not self.proc or not self.proc.alive:
                    self.state = "error"
                    tail = self.proc.lines(15) if self.proc else []
                    self.error = "ACE-Step stopped while starting:\n" + "\n".join(tail)
                    return False
                try:
                    r = await client.get(f"{url}/health", headers=headers)
                    if r.status_code == 200:
                        self.state = "ready"
                        return True
                except httpx.HTTPError:
                    pass
                await asyncio.sleep(2)
        self.state = "error"
        self.error = "ACE-Step did not become ready in time"
        return False

    async def ensure_generation_ready(self) -> str:
        """Make sure something that can generate is up; returns the mode used."""
        if self.mode == "training":
            raise RuntimeError("The PC is training a style right now. Try again when it finishes.")
        if self.mode not in ("api", "studio") or not (self.proc and self.proc.alive):
            await self.switch("api")
        elif self.state == "starting":
            await self.wait_ready()
        if self.state != "ready":
            raise RuntimeError(self.error or "ACE-Step is not ready")
        return self.mode

    def logs(self, tail: int = 200) -> list[str]:
        p = self.last_logs.get("acestep")
        return p.lines(tail) if p else []

    def status(self) -> dict:
        return {
            "mode": self.mode,
            "state": self.state,
            "error": self.error,
            "uptime": round(time.time() - self.proc.started_at) if self.proc and self.proc.alive else 0,
        }

    async def shutdown(self) -> None:
        await asyncio.to_thread(self._stop_current)


def gpu_info() -> Optional[dict]:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip().splitlines()
        if not out:
            return None
        name, used, total, util, temp = [x.strip() for x in out[0].split(",")]
        return {"name": name, "mem_used_mb": int(used), "mem_total_mb": int(total),
                "util": int(util), "temp_c": int(temp)}
    except Exception:
        return None
