"""Phone -> PC song generation through ACE-Step's REST API."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

import httpx

from . import config
from .supervisor import Supervisor


@dataclass
class GenJob:
    id: str
    caption: str
    lyrics: str
    duration: float
    language: str = ""
    adapter: Optional[str] = None
    adapter_scale: float = 1.0
    seed: int = -1
    bpm: int = 0
    simple: bool = False            # description only: ACE-Step's songwriter writes lyrics + style
    source: Optional[str] = None    # path of uploaded source audio (cover / repaint)
    task: str = "new"               # new | cover | repaint
    cover_strength: float = 0.7
    repaint_start: float = 0.0
    repaint_end: float = -1.0
    status: str = "queued"          # queued | starting | running | done | failed
    message: str = ""
    created: float = field(default_factory=time.time)
    finished: float = 0.0
    file: Optional[str] = None
    meta: dict = field(default_factory=dict)

    def public(self) -> dict:
        d = asdict(self)
        d.pop("file")
        d["elapsed"] = round((self.finished or time.time()) - self.created)
        d["has_audio"] = self.file is not None
        return d


class AceStepError(RuntimeError):
    pass


class Generator:
    def __init__(self, sup: Supervisor):
        self.sup = sup
        self.jobs: dict[str, GenJob] = {}
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        self.loaded_adapter: Optional[str] = None   # what ACE-Step (api mode) currently has loaded
        self._worker: Optional[asyncio.Task] = None

    def start(self) -> None:
        self._worker = asyncio.create_task(self._run())

    def submit(self, **kw) -> GenJob:
        job = GenJob(id=uuid.uuid4().hex[:12], **kw)
        self.jobs[job.id] = job
        self.queue.put_nowait(job.id)
        # keep the last 50 jobs in memory
        for old in sorted(self.jobs.values(), key=lambda j: j.created)[:-50]:
            self.jobs.pop(old.id, None)
        return job

    # -- ACE-Step calls ----------------------------------------------------
    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self.sup.base_url or "",
            headers={"Authorization": f"Bearer {self.sup.settings.internal_key}"},
            timeout=httpx.Timeout(60, read=600),
        )

    @staticmethod
    def _unwrap(r: httpx.Response):
        try:
            body = r.json()
        except ValueError:
            raise AceStepError(f"ACE-Step returned HTTP {r.status_code}")
        if r.status_code >= 400:
            raise AceStepError(body.get("detail") or body.get("error") or f"HTTP {r.status_code}")
        if isinstance(body, dict) and "code" in body and body.get("code") not in (200, None):
            raise AceStepError(body.get("error") or f"ACE-Step error {body.get('code')}")
        return body.get("data") if isinstance(body, dict) and "data" in body else body

    async def _apply_adapter(self, client: httpx.AsyncClient, name: Optional[str], scale: float) -> None:
        if self.sup.mode != "api":
            if name:
                raise AceStepError("Styles need the phone server mode. Close the Studio (or switch modes in the app) and try again.")
            return
        if not name:
            if self.loaded_adapter:
                self._unwrap(await client.post("/v1/lora/unload"))
                self.loaded_adapter = None
            return
        peft_dir = config.ADAPTERS / name / "peft"
        if not peft_dir.exists():
            raise AceStepError(f"Style '{name}' has no PC copy. Re-train or re-export it.")
        if self.loaded_adapter != name:
            if self.loaded_adapter:
                self._unwrap(await client.post("/v1/lora/unload"))
                self.loaded_adapter = None
            self._unwrap(await client.post("/v1/lora/load", json={"lora_path": str(peft_dir)}))
            self.loaded_adapter = name
        self._unwrap(await client.post("/v1/lora/scale", json={"scale": max(0.0, min(scale, 1.0))}))

    async def _run(self) -> None:
        while True:
            job_id = await self.queue.get()
            job = self.jobs.get(job_id)
            if not job:
                continue
            try:
                await self._generate(job)
            except Exception as e:  # noqa: BLE001 - surface every failure to the phone
                job.status = "failed"
                job.message = str(e) or e.__class__.__name__
            finally:
                job.finished = time.time()

    async def _generate(self, job: GenJob) -> None:
        job.status = "starting"
        job.message = "Waking up ACE-Step"
        mode_before = self.sup.mode
        await self.sup.ensure_generation_ready()
        if self.sup.mode != mode_before:
            self.loaded_adapter = None  # fresh process, nothing loaded

        async with self._client() as client:
            job.message = "Loading style" if job.adapter else "Preparing"
            await self._apply_adapter(client, job.adapter, job.adapter_scale)

            body = {
                "prompt": job.caption,
                "lyrics": job.lyrics if job.simple else (job.lyrics or "[Instrumental]"),
                "audio_duration": job.duration,
                "thinking": True,            # songwriter LM plans structure -> better vocals
                "use_cot_caption": False,    # keep the user's style prompt exactly as typed
                "batch_size": 1,
                "audio_format": "mp3",
                "inference_steps": 8,
            }
            if job.source and job.task in ("cover", "repaint"):
                body["task_type"] = job.task
                body["src_audio_path"] = job.source
                body["thinking"] = False          # covers follow the source's structure
                body.pop("audio_duration", None)  # length comes from the source
                if job.task == "cover":
                    body["audio_cover_strength"] = max(0.0, min(1.0, job.cover_strength))
                else:
                    body["repainting_start"] = max(0.0, job.repaint_start)
                    body["repainting_end"] = job.repaint_end
            if job.simple:
                body["sample_mode"] = True
                body["sample_query"] = job.caption
            if job.language:
                body["vocal_language"] = job.language
            if job.bpm > 0:
                body["bpm"] = job.bpm
            if job.seed >= 0:
                body["use_random_seed"] = False
                body["seed"] = job.seed

            task = self._unwrap(await client.post("/release_task", json=body))
            task_id = task["task_id"]
            job.status = "running"
            job.message = "Generating"

            result = None
            while True:
                await asyncio.sleep(2)
                rows = self._unwrap(await client.post("/query_result", json={"task_id_list": [task_id]}))
                row = rows[0] if rows else {}
                if row.get("status") == 1:
                    result = row
                    break
                if row.get("status") == 2:
                    raise AceStepError(_failure_text(row))
                if self.sup.mode not in ("api", "studio") or not (self.sup.proc and self.sup.proc.alive):
                    raise AceStepError("ACE-Step stopped during generation")

            items = result.get("result")
            if isinstance(items, str):
                items = json.loads(items)
            item = items[0] if isinstance(items, list) and items else (items or {})
            url = item.get("file")
            if not url:
                raise AceStepError("ACE-Step finished without an audio file")

            job.message = "Downloading"
            out = config.SONGS / f"{job.id}.mp3"
            async with client.stream("GET", url) as r:
                if r.status_code != 200:
                    raise AceStepError(f"audio download failed (HTTP {r.status_code})")
                with out.open("wb") as f:
                    async for chunk in r.aiter_bytes():
                        f.write(chunk)

            metas = item.get("metas") or {}
            seed = str(item.get("seed_value") or "").split(",")[0]
            job.meta = {
                "bpm": _int(metas.get("bpm")),
                "key": metas.get("keyscale") or "",
                "duration": float(metas.get("duration") or job.duration),
                "seed": _int(seed, -1),
                "model": item.get("dit_model") or config.DIT_MODEL,
                "lyrics": item.get("lyrics") or job.lyrics,
            }
            job.file = str(out)
            job.status = "done"
            job.message = ""

    def audio_path(self, job_id: str) -> Optional[Path]:
        job = self.jobs.get(job_id)
        return Path(job.file) if job and job.file else None


def _int(v, default: int = 0) -> int:
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def _failure_text(row: dict) -> str:
    res = row.get("result")
    try:
        items = json.loads(res) if isinstance(res, str) else res
        if isinstance(items, list) and items:
            return items[0].get("error") or items[0].get("generation_info") or "generation failed"
    except (ValueError, AttributeError):
        pass
    return row.get("error") or "generation failed"
