# /// script
# requires-python = ">=3.10"
# ///
"""
prep_dataset.py - turn a folder of your songs into a Side-Step training set.

Layout it expects (subfolders can be nested inside each):

    my_songs/
      vocals/          songs with singing  -> lyrics auto-transcribed with Whisper
      instrumentals/   beats / no vocals   -> lyrics = [Instrumental]
      style.txt        optional: default caption for every song, e.g.
                       "dark trap, 808s, airy pads, male vocal"
      vocals/style.txt optional: overrides the root style.txt for that folder

For every audio file it writes a sidecar <song>.txt next to it in the
"key: value" format Side-Step reads (caption, is_instrumental, lyrics).
Existing sidecars are left alone unless you pass --overwrite, so you can
hand-edit lyrics and re-run safely.

Run it inside Side-Step's environment (it already has torch + CUDA + demucs):

    cd Side-Step
    uv run --with openai-whisper python ..\\trainer\\prep_dataset.py D:\\my_songs
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

AUDIO_EXT = {".wav", ".mp3", ".flac", ".ogg", ".opus", ".m4a"}


def find_style(audio: Path, root: Path) -> str | None:
    """Closest style.txt walking up from the song's folder to the root."""
    d = audio.parent
    while True:
        s = d / "style.txt"
        if s.is_file():
            text = s.read_text(encoding="utf-8").strip()
            if text:
                return text
        if d == root or d.parent == d:
            return None
        d = d.parent


def caption_from_name(audio: Path) -> str:
    return audio.stem.replace("_", " ").replace("-", " ").strip()


def is_instrumental_path(audio: Path, root: Path) -> bool:
    parts = [p.lower() for p in audio.relative_to(root).parts[:-1]]
    if any(p.startswith("instrumental") or p in {"beats", "inst"} for p in parts):
        return True
    if any(p.startswith("vocal") or p in {"songs", "vox"} for p in parts):
        return False
    return False  # unknown folder: treat as vocal, Whisper returns nothing if there's no singing


def isolate_vocals(audio: Path, work: Path) -> Path:
    """Demucs two-stem split. Whisper is far more accurate on a dry vocal."""
    cmd = [sys.executable, "-m", "demucs", "--two-stems", "vocals", "-o", str(work), str(audio)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    hits = list(work.rglob("vocals.wav"))
    if not hits:
        raise RuntimeError("demucs produced no vocals.wav")
    return hits[0]


def transcribe(model, audio: Path, language: str | None) -> str:
    result = model.transcribe(
        str(audio),
        language=language,
        condition_on_previous_text=False,  # stops Whisper looping a chorus forever
        no_speech_threshold=0.6,
        fp16=True,
    )
    lines: list[str] = []
    last_end = None
    for seg in result.get("segments", []):
        text = seg["text"].strip()
        if not text:
            continue
        # Blank line between phrases separated by a long gap = rough section break.
        if last_end is not None and seg["start"] - last_end > 4.0:
            lines.append("")
        lines.append(text)
        last_end = seg["end"]
    return "\n".join(lines).strip()


def write_sidecar(path: Path, caption: str, instrumental: bool, lyrics: str) -> None:
    body = [
        f"caption: {caption}",
        f"is_instrumental: {'true' if instrumental else 'false'}",
        "lyrics:",
        lyrics,
    ]
    path.write_text("\n".join(body).rstrip() + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("songs", type=Path, help="folder with vocals/ and instrumentals/")
    ap.add_argument("--language", default=None, help="force a Whisper language code, e.g. en (default: auto)")
    ap.add_argument("--whisper-model", default="turbo", help="Whisper model name (default: turbo = large-v3-turbo)")
    ap.add_argument("--no-isolate", action="store_true", help="skip Demucs vocal isolation (faster, less accurate)")
    ap.add_argument("--overwrite", action="store_true", help="rewrite sidecars that already exist")
    args = ap.parse_args()

    root = args.songs.resolve()
    if not root.is_dir():
        print(f"Not a folder: {root}")
        return 1

    files = sorted(p for p in root.rglob("*") if p.suffix.lower() in AUDIO_EXT and p.is_file())
    if not files:
        print(f"No audio found in {root}")
        return 1

    todo = [f for f in files if args.overwrite or not f.with_suffix(".txt").exists()]
    vocal = [f for f in todo if not is_instrumental_path(f, root)]
    print(f"{len(files)} songs found, {len(todo)} need sidecars ({len(vocal)} vocal, {len(todo) - len(vocal)} instrumental)")

    model = None
    if vocal:
        import whisper  # openai-whisper, added with `uv run --with openai-whisper`

        print(f"Loading Whisper '{args.whisper_model}' on the GPU...")
        model = whisper.load_model(args.whisper_model, device="cuda")

    for i, audio in enumerate(todo, 1):
        instrumental = is_instrumental_path(audio, root)
        caption = find_style(audio, root) or caption_from_name(audio)
        lyrics = "[Instrumental]"
        if not instrumental:
            src = audio
            tmp = None
            try:
                if not args.no_isolate:
                    tmp = Path(tempfile.mkdtemp(prefix="sf_demucs_"))
                    src = isolate_vocals(audio, tmp)
                text = transcribe(model, src, args.language)
            finally:
                if tmp is not None:
                    shutil.rmtree(tmp, ignore_errors=True)
            if text:
                lyrics = text
            else:
                instrumental = True  # Whisper heard no words
        write_sidecar(audio.with_suffix(".txt"), caption, instrumental, lyrics)
        kind = "instrumental" if instrumental else f"{lyrics.count(chr(10)) + 1} lyric lines"
        print(f"[{i}/{len(todo)}] {audio.name}: {kind}")

    print("\nDone. Open the .txt files next to your songs and fix any misheard lyrics before training.")
    print("Adding [Verse] / [Chorus] tags above sections helps the model learn song structure.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
