"""Paths, ports and the persistent pairing token."""

from __future__ import annotations

import json
import os
import secrets
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

# pc/ folder (hub/ lives inside it)
PC_DIR = Path(os.environ.get("SIGNATURE_HOME", Path(__file__).resolve().parents[2]))
RUNTIME = PC_DIR / "runtime"
DATA = PC_DIR / "data"

ACESTEP_DIR = RUNTIME / "ACE-Step-1.5"
SIDESTEP_DIR = RUNTIME / "Side-Step"
CHECKPOINTS = ACESTEP_DIR / "checkpoints"  # shared by ACE-Step and Side-Step

DATASETS = DATA / "datasets"
ADAPTERS = DATA / "adapters"
WORK = DATA / "work"
SONGS = DATA / "songs"
SETTINGS_FILE = DATA / "hub.json"

PREP_SCRIPT = Path(__file__).with_name("prep_dataset.py")

IS_WINDOWS = sys.platform == "win32"

HUB_PORT = int(os.environ.get("SIGNATURE_PORT", "8790"))
STUDIO_PORT = 7860
API_PORT = 8001

DIT_MODEL = "acestep-v15-turbo"          # the phone runs turbo too
LM_MODEL = "acestep-5Hz-lm-1.7B"         # included in ACE-Step's default download


def uv_exe() -> str:
    found = shutil.which("uv")
    if found:
        return found
    home = Path.home()
    for cand in (home / ".local" / "bin" / ("uv.exe" if IS_WINDOWS else "uv"),
                 home / ".cargo" / "bin" / ("uv.exe" if IS_WINDOWS else "uv")):
        if cand.exists():
            return str(cand)
    return "uv"


@dataclass
class Settings:
    token: str = field(default_factory=lambda: secrets.token_urlsafe(24))
    internal_key: str = field(default_factory=lambda: secrets.token_urlsafe(24))  # hub -> ACE-Step
    default_mode: str = "api"   # what to run when nothing else is going on: api | studio | idle

    @classmethod
    def load(cls) -> "Settings":
        for d in (DATASETS, ADAPTERS, WORK, SONGS):
            d.mkdir(parents=True, exist_ok=True)
        if SETTINGS_FILE.exists():
            try:
                raw = json.loads(SETTINGS_FILE.read_text("utf-8"))
                s = cls(**{k: v for k, v in raw.items() if k in cls.__dataclass_fields__})
                s.save()
                return s
            except Exception:
                pass
        s = cls()
        s.save()
        return s

    def save(self) -> None:
        SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps(self.__dict__, indent=2), "utf-8")

    def rotate_token(self) -> None:
        self.token = secrets.token_urlsafe(24)
        self.save()
