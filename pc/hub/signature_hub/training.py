"""Style training with Side-Step, tuned for a 12 GB card (RTX 3080 Ti).

Pipeline (each step is a subprocess in Side-Step's own environment):
  1 lyrics     Whisper (+ Demucs vocal isolation) writes sidecars for unlabeled songs
  2 analyze    BPM / key / time signature, fills only what's missing
  3 dataset    dataset.json with the trigger word prepended to every caption
  4 tensors    VAE + text-encoder preprocessing (turbo)
  5 train      LoRA rank 32, AdamW8bit, encoder offload, 60 s chunks
  6 export     one .safetensors for the phone + the PEFT folder for the PC
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
import time
from dataclasses import dataclass, field
from typing import Optional

from . import config, datasets
from .supervisor import ManagedProcess, Supervisor

EPOCH_RE = re.compile(r"[Ee]poch\s*[:#]?\s*(\d+)\s*(?:/|of)\s*(\d+)")
STEP_RE = re.compile(r"\b[Ss]tep\s*[:#]?\s*(\d+)\s*(?:/|of)\s*(\d+)")
LOSS_RE = re.compile(r"\bloss\b\s*[=:]\s*([0-9]*\.?[0-9]+(?:e-?\d+)?)", re.I)
PCT_RE = re.compile(r"(\d{1,3})%\|")


@dataclass
class TrainJob:
    kind: str                 # "label" or "train"
    dataset: str
    epochs: int = 800
    rank: int = 32
    status: str = "running"   # running | done | failed | cancelled
    step: int = 0
    steps: list[str] = field(default_factory=list)
    step_name: str = ""
    epoch: int = 0
    epochs_total: int = 0
    loss: Optional[float] = None
    losses: list[float] = field(default_factory=list)
    percent: Optional[int] = None
    message: str = ""
    started: float = field(default_factory=time.time)
    finished: float = 0.0

    def public(self) -> dict:
        d = {k: v for k, v in self.__dict__.items() if k != "losses"}
        d["losses"] = self.losses[-200:]
        d["elapsed"] = round((self.finished or time.time()) - self.started)
        return d


class Trainer:
    def __init__(self, sup: Supervisor):
        self.sup = sup
        self.job: Optional[TrainJob] = None
        self.proc: Optional[ManagedProcess] = None
        self._task: Optional[asyncio.Task] = None
        self._cancel = False

    @property
    def busy(self) -> bool:
        return self.job is not None and self.job.status == "running"

    def logs(self, tail: int = 200) -> list[str]:
        return self.proc.lines(tail) if self.proc else []

    def start(self, kind: str, dataset: str, epochs: int = 800, rank: int = 32) -> TrainJob:
        if self.busy:
            raise RuntimeError("A training job is already running")
        if not config.SIDESTEP_DIR.exists():
            raise RuntimeError("Side-Step is not installed. Run install.bat.")
        files = datasets.audio_files(dataset)
        if not files:
            raise RuntimeError("Add some songs to this dataset first")
        if kind == "train" and len(files) < 3:
            raise RuntimeError("Add at least 3 songs (10-20+ recommended)")
        rank = rank if rank in (8, 16, 32, 64) else 32
        epochs = max(10, min(int(epochs), 3000))
        job = TrainJob(kind=kind, dataset=dataset, epochs=epochs, rank=rank)
        job.steps = ["Lyrics"] if kind == "label" else ["Lyrics", "Analyze", "Dataset", "Tensors", "Train", "Export"]
        self.job = job
        self._cancel = False
        self._task = asyncio.create_task(self._run(job))
        return job

    async def cancel(self) -> None:
        self._cancel = True
        if self.proc:
            await asyncio.to_thread(self.proc.stop)

    # ---- pipeline -----------------------------------------------------------
    async def _run(self, job: TrainJob) -> None:
        resume_mode = self.sup.mode if self.sup.mode in ("api", "studio") else self.sup.settings.default_mode
        try:
            job.message = "Freeing the GPU"
            await self.sup.switch("training")
            ds = datasets.require(job.dataset)
            work = config.WORK / job.dataset
            tensors = work / "tensors"
            lora = work / "lora"
            out_dir = config.ADAPTERS / job.dataset
            ss = [config.uv_exe(), "run", "sidestep"]
            ckpt = ["--checkpoint-dir", str(config.CHECKPOINTS), "--model", "turbo"]

            await self._step(job, 0, [config.uv_exe(), "run", "--with", "openai-whisper", "python",
                                      str(config.PREP_SCRIPT), str(ds)])
            if job.kind == "label":
                job.status = "done"
                job.message = "Lyrics written. Review them, then train."
                return

            await self._step(job, 1, ss + ["audio-analyze", "--input", str(ds), "--mode", "mid",
                                           "--policy", "fill_missing"])
            await self._step(job, 2, ss + ["dataset", "--input", str(ds), "--tag", job.dataset,
                                           "--tag-position", "prepend", "--name", job.dataset,
                                           "--output", str(ds / "dataset.json")])
            shutil.rmtree(tensors, ignore_errors=True)
            await self._step(job, 3, ss + ["preprocess", "--audio-dir", str(ds),
                                           "--dataset-json", str(ds / "dataset.json"),
                                           "--output", str(tensors)] + ckpt)
            shutil.rmtree(lora, ignore_errors=True)
            job.epochs_total = job.epochs
            await self._step(job, 4, ss + [
                "train", *ckpt,
                "--dataset-dir", str(tensors), "--output-dir", str(lora),
                "--adapter", "lora", "--rank", str(job.rank), "--alpha", str(job.rank * 2),
                "--dropout", "0.1", "--target-mlp", "--attention-type", "both",
                "--lr", "3e-4", "--batch-size", "1", "--gradient-accumulation", "4",
                "--warmup-steps", "100", "--epochs", str(job.epochs),
                "--optimizer-type", "adamw8bit", "--scheduler-type", "cosine",
                "--gradient-checkpointing", "--offload-encoder", "--chunk-duration", "60",
                "--save-every", "50", "--save-best", "--num-workers", "0",
            ])
            final = lora / "final"
            if not final.exists():
                raise RuntimeError("Training finished but no final adapter was saved")
            out_dir.mkdir(parents=True, exist_ok=True)
            phone_file = out_dir / f"{job.dataset}.safetensors"
            await self._step(job, 5, ss + ["export", str(final), "--output", str(phone_file),
                                           "--target", "native"])
            peft = out_dir / "peft"
            shutil.rmtree(peft, ignore_errors=True)
            shutil.copytree(final, peft)
            (out_dir / "info.json").write_text(json.dumps({
                "name": job.dataset, "epochs": job.epochs, "rank": job.rank,
                "songs": len(datasets.audio_files(job.dataset)), "final_loss": job.loss,
                "trained_at": time.time(), "base_model": config.DIT_MODEL,
            }, indent=2), "utf-8")
            job.status = "done"
            job.message = f"Style '{job.dataset}' is ready"
        except asyncio.CancelledError:
            job.status = "cancelled"
            raise
        except Exception as e:  # noqa: BLE001
            job.status = "cancelled" if self._cancel else "failed"
            job.message = "Cancelled" if self._cancel else str(e)
        finally:
            job.finished = time.time()
            self.proc = None if job.status == "done" else self.proc
            await self.sup.switch(resume_mode if resume_mode != "training" else "idle", wait=False)

    async def _step(self, job: TrainJob, idx: int, cmd: list[str]) -> None:
        if self._cancel:
            raise RuntimeError("Cancelled")
        job.step = idx
        job.step_name = job.steps[idx]
        job.percent = None
        job.message = {0: "Transcribing lyrics", 1: "Detecting tempo and key", 2: "Building dataset",
                       3: "Preprocessing audio", 4: "Training", 5: "Exporting"}[idx]
        proc = ManagedProcess(f"train:{job.steps[idx].lower()}", cmd, cwd=config.SIDESTEP_DIR)
        self.proc = proc
        proc.start()
        seen = 0
        while proc.alive:
            await asyncio.sleep(1)
            seen = self._parse(job, proc, seen)
        self._parse(job, proc, seen)
        if self._cancel:
            raise RuntimeError("Cancelled")
        if proc.exit_code != 0:
            tail = [l for l in proc.lines(12) if l.strip()]
            raise RuntimeError(f"{job.steps[idx]} step failed:\n" + "\n".join(tail[-8:]))

    @staticmethod
    def _parse(job: TrainJob, proc: ManagedProcess, seen: int) -> int:
        lines = proc.lines(400)
        for line in lines[-40:]:
            m = PCT_RE.search(line)
            if m:
                job.percent = min(100, int(m.group(1)))
        for line in lines:
            m = EPOCH_RE.search(line)
            if m and job.step_name == "Train":
                job.epoch, total = int(m.group(1)), int(m.group(2))
                if total >= job.epoch:
                    job.epochs_total = total
            m = LOSS_RE.search(line)
            if m and job.step_name == "Train":
                try:
                    job.loss = float(m.group(1))
                except ValueError:
                    pass
        # record a loss sample for the chart about once per new log batch
        total_lines = len(proc.log)
        if job.loss is not None and total_lines != seen:
            if not job.losses or job.losses[-1] != job.loss:
                job.losses.append(job.loss)
        return total_lines


def adapters() -> list[dict]:
    out = []
    if not config.ADAPTERS.exists():
        return out
    for d in sorted(config.ADAPTERS.iterdir()):
        f = d / f"{d.name}.safetensors"
        if not f.exists():
            continue
        info = {}
        try:
            info = json.loads((d / "info.json").read_text("utf-8"))
        except (OSError, ValueError):
            pass
        out.append({
            "name": d.name,
            "bytes": f.stat().st_size,
            "trained_at": info.get("trained_at", f.stat().st_mtime),
            "epochs": info.get("epochs"),
            "songs": info.get("songs"),
            "final_loss": info.get("final_loss"),
            "pc_ready": (d / "peft").exists(),
        })
    return out
