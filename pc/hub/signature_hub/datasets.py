"""Training song collections. One dataset per style; its name is the trigger word.

data/datasets/<name>/
    style.txt            default caption for every song
    vocals/<song>.mp3    + <song>.txt sidecar (caption / is_instrumental / lyrics)
    instrumentals/<song>.wav
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Optional

from . import config

NAME_RE = re.compile(r"^[a-z0-9_]{2,32}$")
AUDIO_EXT = {".wav", ".mp3", ".flac", ".ogg", ".opus", ".m4a"}
KINDS = ("vocals", "instrumentals")
SIDECAR_KEYS = ("caption", "genre", "bpm", "key", "signature", "is_instrumental", "custom_tag",
                "prompt_override", "repeat")


class DatasetError(ValueError):
    pass


def check_name(name: str) -> str:
    if not NAME_RE.match(name or ""):
        raise DatasetError("Use 2-32 lowercase letters, numbers or _ (this becomes your trigger word).")
    return name


def path(name: str) -> Path:
    return config.DATASETS / check_name(name)


def create(name: str, style: str = "") -> dict:
    p = path(name)
    if p.exists():
        raise DatasetError(f"'{name}' already exists")
    for k in KINDS:
        (p / k).mkdir(parents=True)
    (p / "style.txt").write_text(style.strip(), "utf-8")
    return summary(name)


def delete(name: str) -> None:
    shutil.rmtree(path(name), ignore_errors=True)
    shutil.rmtree(config.WORK / name, ignore_errors=True)


def set_style(name: str, style: str) -> None:
    (require(name) / "style.txt").write_text(style.strip(), "utf-8")


def require(name: str) -> Path:
    p = path(name)
    if not p.is_dir():
        raise DatasetError(f"No dataset named '{name}'")
    return p


def audio_files(name: str) -> list[Path]:
    root = require(name)
    return sorted(f for f in root.rglob("*") if f.is_file() and f.suffix.lower() in AUDIO_EXT)


def song_id(root: Path, f: Path) -> str:
    return f.relative_to(root).as_posix()


def resolve_song(name: str, sid: str) -> Path:
    root = require(name)
    f = (root / sid).resolve()
    if root.resolve() not in f.parents or f.suffix.lower() not in AUDIO_EXT or not f.is_file():
        raise DatasetError("Unknown song")
    return f


def summary(name: str) -> dict:
    root = require(name)
    files = audio_files(name)
    labeled = sum(1 for f in files if f.with_suffix(".txt").exists())
    style_file = root / "style.txt"
    return {
        "name": name,
        "style": style_file.read_text("utf-8").strip() if style_file.exists() else "",
        "songs": len(files),
        "vocals": sum(1 for f in files if f.relative_to(root).parts[0] == "vocals"),
        "instrumentals": sum(1 for f in files if f.relative_to(root).parts[0] == "instrumentals"),
        "labeled": labeled,
        "bytes": sum(f.stat().st_size for f in files),
        "trained": (config.ADAPTERS / name / f"{name}.safetensors").exists(),
    }


def list_all() -> list[dict]:
    out = []
    for d in sorted(config.DATASETS.iterdir()) if config.DATASETS.exists() else []:
        if d.is_dir() and NAME_RE.match(d.name):
            out.append(summary(d.name))
    return out


def save_upload(name: str, kind: str, filename: str, stream) -> dict:
    if kind not in KINDS:
        raise DatasetError("kind must be vocals or instrumentals")
    root = require(name)
    clean = re.sub(r"[^\w\-. ()]+", "_", Path(filename).name).strip() or "song"
    if Path(clean).suffix.lower() not in AUDIO_EXT:
        raise DatasetError(f"{filename}: not an audio file ({', '.join(sorted(AUDIO_EXT))})")
    dest = root / kind / clean
    stem, ext, n = dest.stem, dest.suffix, 2
    while dest.exists():
        dest = root / kind / f"{stem} ({n}){ext}"
        n += 1
    with dest.open("wb") as f:
        shutil.copyfileobj(stream, f, length=1024 * 1024)
    return song_info(root, dest)


def delete_song(name: str, sid: str) -> None:
    f = resolve_song(name, sid)
    f.unlink()
    for side in (f.with_suffix(".txt"), f.with_suffix(".txt.bak")):
        side.unlink(missing_ok=True)


# ---- sidecars -------------------------------------------------------------
def read_sidecar(f: Path) -> dict:
    """Same 'key: value' + trailing 'lyrics:' block format Side-Step uses."""
    side = f.with_suffix(".txt")
    if not side.exists():
        return {}
    meta: dict[str, str] = {}
    key: Optional[str] = None
    buf: list[str] = []
    for line in side.read_text("utf-8", errors="replace").splitlines():
        if key == "lyrics":
            buf.append(line)
            continue
        head, sep, rest = line.partition(":")
        cand = head.strip().lower()
        if sep and (cand in SIDECAR_KEYS or cand == "lyrics"):
            if key:
                meta[key] = "\n".join(buf).strip()
            key, buf = cand, [rest.strip()] if rest.strip() else []
        elif key:
            buf.append(line)
    if key:
        meta[key] = "\n".join(buf).strip()
    return meta


def write_sidecar(f: Path, data: dict) -> None:
    current = read_sidecar(f)
    current.update({k: v for k, v in data.items() if v is not None})
    lines = [f"{k}: {current[k]}" for k in SIDECAR_KEYS if str(current.get(k, "")).strip()]
    lines.append("lyrics:")
    lines.append(str(current.get("lyrics", "")).strip())
    f.with_suffix(".txt").write_text("\n".join(lines).rstrip() + "\n", "utf-8")


def song_info(root: Path, f: Path) -> dict:
    side = read_sidecar(f)
    return {
        "id": song_id(root, f),
        "name": f.stem,
        "kind": f.relative_to(root).parts[0],
        "bytes": f.stat().st_size,
        "labeled": bool(side),
        "caption": side.get("caption", ""),
        "lyrics": side.get("lyrics", ""),
        "is_instrumental": side.get("is_instrumental", "").lower() == "true",
        "bpm": side.get("bpm", ""),
        "key": side.get("key", ""),
    }


def songs(name: str) -> list[dict]:
    root = require(name)
    return [song_info(root, f) for f in audio_files(name)]


def update_song(name: str, sid: str, caption: Optional[str], lyrics: Optional[str],
                is_instrumental: Optional[bool]) -> dict:
    f = resolve_song(name, sid)
    data: dict = {}
    if caption is not None:
        data["caption"] = caption.strip()
        if not data["caption"]:
            style = require(name) / "style.txt"
            data["caption"] = (style.read_text("utf-8").strip() if style.exists() else "") or f.stem
    if lyrics is not None:
        data["lyrics"] = lyrics.strip() or "[Instrumental]"
    if is_instrumental is not None:
        data["is_instrumental"] = "true" if is_instrumental else "false"
        if is_instrumental:
            data["lyrics"] = "[Instrumental]"
    existing = read_sidecar(f)
    if "is_instrumental" not in existing and "is_instrumental" not in data:
        inst = f.relative_to(require(name)).parts[0] == "instrumentals"
        data["is_instrumental"] = "true" if inst else "false"
        if inst and "lyrics" not in data:
            data["lyrics"] = "[Instrumental]"
    if "caption" not in existing and "caption" not in data:
        style = (require(name) / "style.txt")
        data["caption"] = style.read_text("utf-8").strip() if style.exists() else f.stem
    write_sidecar(f, data)
    return song_info(require(name), f)
