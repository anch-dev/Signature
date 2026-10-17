"""Signature Hub HTTP server (default port 8790).

Phone endpoints need `Authorization: Bearer <token>` (or ?token= for file
downloads). The dashboard at / is only served to this PC itself.
"""

from __future__ import annotations

import asyncio
import io
import ipaddress
import socket
import subprocess
import time
import webbrowser
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import psutil
import qrcode
import qrcode.image.svg
import uvicorn
from fastapi import Depends, FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field

from . import __version__, config, datasets, yue2
from .generation import Generator
from .supervisor import Supervisor, gpu_info
from .training import Trainer, adapters

settings = config.Settings.load()
sup = Supervisor(settings)
gen = Generator(sup)
trainer = Trainer(sup)
STATIC = Path(__file__).with_name("static")


@asynccontextmanager
async def lifespan(app: FastAPI):
    gen.start()
    if settings.default_mode in ("api", "studio") and config.ACESTEP_DIR.exists():
        asyncio.create_task(sup.switch(settings.default_mode))
    yield
    await trainer.cancel()
    await sup.shutdown()


app = FastAPI(title="Signature Hub", version=__version__, lifespan=lifespan)


# ---- auth ---------------------------------------------------------------
def _is_local(request: Request) -> bool:
    host = request.client.host if request.client else ""
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


def auth(request: Request, token: Optional[str] = Query(default=None)) -> None:
    header = request.headers.get("authorization", "")
    given = header[7:] if header.lower().startswith("bearer ") else token
    if given and given == settings.token:
        return
    raise HTTPException(status_code=401, detail="Pair this phone with the Hub first (wrong or missing token)")


def local_only(request: Request) -> None:
    if not _is_local(request):
        raise HTTPException(status_code=403, detail="Only available on the PC itself")


@app.exception_handler(datasets.DatasetError)
async def _dataset_error(_: Request, exc: datasets.DatasetError):
    return JSONResponse(status_code=400, content={"detail": str(exc)})


# ---- network info / pairing ------------------------------------------------
def addresses() -> list[dict]:
    """LAN and Tailscale addresses the phone could reach this PC on."""
    out: list[dict] = []
    seen = set()
    for iface, addrs in psutil.net_if_addrs().items():
        for a in addrs:
            if a.family != socket.AF_INET:
                continue
            ip = ipaddress.ip_address(a.address)
            if ip.is_loopback or ip.is_link_local or a.address in seen:
                continue
            seen.add(a.address)
            tailscale = ip in ipaddress.ip_network("100.64.0.0/10") or "tailscale" in iface.lower()
            if tailscale or ip.is_private:
                out.append({"ip": a.address, "interface": iface, "kind": "tailscale" if tailscale else "lan"})
    out.sort(key=lambda x: (x["kind"] != "lan", x["ip"]))
    try:
        dns = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=4)
        if dns.returncode == 0:
            import json as _json
            name = _json.loads(dns.stdout).get("Self", {}).get("DNSName", "").rstrip(".")
            if name:
                out.append({"ip": name, "interface": "tailscale", "kind": "tailscale"})
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return out


def pair_link(host: str) -> str:
    url = f"http://{host}:{config.HUB_PORT}"
    return f"signature://pair?url={quote(url, safe='')}&token={quote(settings.token, safe='')}&name={quote(socket.gethostname(), safe='')}"


# ---- dashboard (PC only) -------------------------------------------------
@app.get("/", response_class=HTMLResponse, dependencies=[Depends(local_only)])
async def dashboard():
    html = (STATIC / "index.html").read_text("utf-8")
    return html.replace("__TOKEN__", settings.token)


@app.get("/pair/qr.svg", dependencies=[Depends(local_only)])
async def pair_qr(host: str):
    img = qrcode.make(pair_link(host), image_factory=qrcode.image.svg.SvgPathImage, box_size=10, border=2)
    buf = io.BytesIO()
    img.save(buf)
    return Response(buf.getvalue(), media_type="image/svg+xml")


@app.get("/pair/info", dependencies=[Depends(local_only)])
async def pair_info():
    return {"addresses": [{**a, "link": pair_link(a["ip"])} for a in addresses()],
            "port": config.HUB_PORT, "token": settings.token, "name": socket.gethostname()}


@app.post("/pair/rotate", dependencies=[Depends(local_only)])
async def pair_rotate():
    settings.rotate_token()
    return {"ok": True}


# ---- status ----------------------------------------------------------------
@app.get("/api/ping")
async def ping():
    """Unauthenticated reachability check for the phone's connection test."""
    return {"app": "signature-hub", "version": __version__, "name": socket.gethostname()}


@app.get("/api/status", dependencies=[Depends(auth)])
async def status():
    return {
        "version": __version__,
        "name": socket.gethostname(),
        "installed": {"acestep": config.ACESTEP_DIR.exists(), "sidestep": config.SIDESTEP_DIR.exists()},
        "engine": sup.status(),
        "default_mode": settings.default_mode,
        "studio_port": config.STUDIO_PORT,
        "gpu": await asyncio.to_thread(gpu_info),
        "training": trainer.job.public() if trainer.job else None,
        "queue": sum(1 for j in gen.jobs.values() if j.status in ("queued", "starting", "running")),
        "loaded_style": gen.loaded_adapter,
        "yue2": yue2.status(),
    }


class ModeBody(BaseModel):
    mode: str
    make_default: bool = False


@app.post("/api/mode", dependencies=[Depends(auth)])
async def set_mode(body: ModeBody):
    if body.mode not in ("api", "studio", "idle"):
        raise HTTPException(400, "mode must be api, studio or idle")
    if trainer.busy:
        raise HTTPException(409, "Training is running. Cancel it first or wait for it to finish.")
    if body.make_default:
        settings.default_mode = body.mode
        settings.save()
    gen.loaded_adapter = None
    asyncio.create_task(sup.switch(body.mode))
    await asyncio.sleep(0.2)
    return sup.status()


@app.get("/api/logs", dependencies=[Depends(auth)])
async def logs(source: str = "engine", tail: int = Query(200, le=2000)):
    if source == "training":
        lines = trainer.logs(tail)
    elif source == "yue2" or (source == "engine" and yue2.runner.recently_active):
        lines = yue2.runner.lines(tail)
    else:
        lines = sup.logs(tail)
    return {"source": source, "lines": lines}


# ---- generation --------------------------------------------------------------
class SoundBody(BaseModel):
    weirdness: float = Field(default=0.5, ge=0, le=1)
    style_influence: float = Field(default=0.5, ge=0, le=1)
    clarity: float = Field(default=0.5, ge=0, le=1)
    sampler: str = "smooth"      # smooth | organic | crisp
    quality: str = "standard"    # fast | standard | high


class GenBody(BaseModel):
    caption: str = Field(min_length=1, max_length=2000)
    lyrics: str = Field(default="", max_length=8000)
    duration: float = Field(default=90, ge=10, le=600)
    language: str = ""
    style: Optional[str] = None
    style_scale: float = Field(default=1.0, ge=0, le=2)
    seed: int = -1
    bpm: int = 0
    simple: bool = False
    enhance: bool = True
    source: Optional[str] = None
    task: str = "new"
    cover_strength: float = Field(default=0.7, ge=0, le=1)
    repaint_start: float = 0.0
    repaint_end: float = -1.0
    sound: Optional[SoundBody] = None
    engine: str = "acestep"          # acestep | yue2
    cot: str = "off"                 # yue2 planning: off | melody | full


@app.post("/api/sources", dependencies=[Depends(auth)])
async def upload_source(file: UploadFile = File(...)):
    """Audio a phone wants covered / repainted. Returns an id for /api/generate."""
    import re as _re
    import shutil as _shutil
    import uuid as _uuid
    ext = Path(file.filename or "").suffix.lower()
    if ext not in (".wav", ".mp3", ".flac", ".m4a", ".ogg", ".opus"):
        raise HTTPException(400, "Send WAV, MP3, FLAC, M4A, OGG or Opus audio")
    sid = _uuid.uuid4().hex[:16] + ext
    dest = config.SOURCES / sid
    with dest.open("wb") as out:
        await asyncio.to_thread(_shutil.copyfileobj, file.file, out, 1024 * 1024)
    # keep the 30 most recent uploads
    for old in sorted(config.SOURCES.iterdir(), key=lambda p: p.stat().st_mtime)[:-30]:
        old.unlink(missing_ok=True)
    return {"id": sid}


@app.post("/api/generate", dependencies=[Depends(auth)])
async def generate(body: GenBody):
    if trainer.busy:
        raise HTTPException(409, "The PC is training a style. Generate on the phone or wait for training to finish.")
    if body.style:
        datasets.check_name(body.style)
    job = gen.submit(caption=body.caption, lyrics=body.lyrics, duration=body.duration, language=body.language,
                     adapter=body.style, adapter_scale=body.style_scale, seed=body.seed, bpm=body.bpm,
                     simple=body.simple, enhance=body.enhance, task=body.task if body.task in ("new", "cover", "repaint") else "new",
                     source=_source_path(body.source), cover_strength=body.cover_strength,
                     repaint_start=body.repaint_start, repaint_end=body.repaint_end,
                     sound=(body.sound or SoundBody()).model_dump(),
                     engine=body.engine if body.engine in ("acestep", "yue2") else "acestep",
                     cot=body.cot)
    return job.public()


def _source_path(sid: Optional[str]) -> Optional[str]:
    if not sid:
        return None
    if "/" in sid or "\\" in sid or sid.startswith("."):
        raise HTTPException(400, "Bad source id")
    p = config.SOURCES / sid
    if not p.exists():
        raise HTTPException(404, "Source audio expired; upload it again")
    return str(p.resolve())


@app.get("/api/jobs", dependencies=[Depends(auth)])
async def jobs():
    return [j.public() for j in sorted(gen.jobs.values(), key=lambda j: -j.created)]


@app.get("/api/jobs/{job_id}", dependencies=[Depends(auth)])
async def job(job_id: str):
    j = gen.jobs.get(job_id)
    if not j:
        raise HTTPException(404, "Unknown job")
    return j.public()


@app.get("/api/jobs/{job_id}/audio", dependencies=[Depends(auth)])
async def job_audio(job_id: str):
    p = gen.audio_path(job_id)
    if not p or not p.exists():
        raise HTTPException(404, "No audio for this job")
    media = "audio/wav" if p.suffix == ".wav" else "audio/mpeg"
    return FileResponse(p, media_type=media, filename=f"{job_id}{p.suffix}")


# ---- datasets ------------------------------------------------------------------
class NewDataset(BaseModel):
    name: str
    style: str = ""


class StyleBody(BaseModel):
    style: str


class SongEdit(BaseModel):
    caption: Optional[str] = None
    lyrics: Optional[str] = None
    is_instrumental: Optional[bool] = None


@app.get("/api/datasets", dependencies=[Depends(auth)])
async def list_datasets():
    return datasets.list_all()


@app.post("/api/datasets", dependencies=[Depends(auth)])
async def create_dataset(body: NewDataset):
    return datasets.create(body.name, body.style)


@app.get("/api/datasets/{name}", dependencies=[Depends(auth)])
async def get_dataset(name: str):
    return {**datasets.summary(name), "items": datasets.songs(name)}


@app.put("/api/datasets/{name}/style", dependencies=[Depends(auth)])
async def put_style(name: str, body: StyleBody):
    datasets.set_style(name, body.style)
    return datasets.summary(name)


@app.delete("/api/datasets/{name}", dependencies=[Depends(auth)])
async def delete_dataset(name: str):
    if trainer.busy and trainer.job and trainer.job.dataset == name:
        raise HTTPException(409, "This dataset is being trained")
    datasets.delete(name)
    return {"ok": True}


@app.post("/api/datasets/{name}/songs", dependencies=[Depends(auth)])
async def upload_songs(name: str, kind: str = Form(...), files: list[UploadFile] = File(...)):
    added = []
    for f in files:
        added.append(await asyncio.to_thread(datasets.save_upload, name, kind, f.filename or "song", f.file))
    return {"added": added, "summary": datasets.summary(name)}


@app.put("/api/datasets/{name}/songs/{song_id:path}", dependencies=[Depends(auth)])
async def edit_song(name: str, song_id: str, body: SongEdit):
    return datasets.update_song(name, song_id, body.caption, body.lyrics, body.is_instrumental)


@app.delete("/api/datasets/{name}/songs/{song_id:path}", dependencies=[Depends(auth)])
async def remove_song(name: str, song_id: str):
    datasets.delete_song(name, song_id)
    return datasets.summary(name)


# ---- training --------------------------------------------------------------------
class TrainBody(BaseModel):
    dataset: str
    kind: str = "train"   # "label" = only transcribe lyrics
    epochs: int = 800
    rank: int = 32


@app.post("/api/train", dependencies=[Depends(auth)])
async def train(body: TrainBody):
    datasets.require(body.dataset)
    if body.kind not in ("train", "label"):
        raise HTTPException(400, "kind must be train or label")
    busy = [j for j in gen.jobs.values() if j.status in ("queued", "starting", "running")]
    if busy:
        raise HTTPException(409, "A song is generating on the PC. Try again when it finishes.")
    try:
        job = trainer.start(body.kind, body.dataset, body.epochs, body.rank)
    except RuntimeError as e:
        raise HTTPException(409, str(e))
    return job.public()


@app.get("/api/train", dependencies=[Depends(auth)])
async def train_status():
    return trainer.job.public() if trainer.job else None


@app.post("/api/train/cancel", dependencies=[Depends(auth)])
async def train_cancel():
    await trainer.cancel()
    return {"ok": True}


# ---- styles (adapters) -------------------------------------------------------------
@app.get("/api/styles", dependencies=[Depends(auth)])
async def styles():
    return adapters()


@app.get("/api/styles/{name}/file", dependencies=[Depends(auth)])
async def style_file(name: str):
    datasets.check_name(name)
    f = config.ADAPTERS / name / f"{name}.safetensors"
    if not f.exists():
        raise HTTPException(404, "No such style")
    return FileResponse(f, media_type="application/octet-stream", filename=f.name)


@app.delete("/api/styles/{name}", dependencies=[Depends(auth)])
async def delete_style(name: str):
    import shutil
    datasets.check_name(name)
    if gen.loaded_adapter == name:
        raise HTTPException(409, "That style is loaded right now. Switch modes first.")
    shutil.rmtree(config.ADAPTERS / name, ignore_errors=True)
    return {"ok": True}


def run() -> None:
    print(f"\n  Signature Hub {__version__}")
    print(f"  Dashboard:  http://localhost:{config.HUB_PORT}")
    for a in addresses():
        print(f"  Phone ({a['kind']}): http://{a['ip']}:{config.HUB_PORT}")
    print()
    try:
        webbrowser.open(f"http://localhost:{config.HUB_PORT}")
    except Exception:
        pass
    uvicorn.run(app, host="0.0.0.0", port=config.HUB_PORT, log_level="warning")


if __name__ == "__main__":
    run()
