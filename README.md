# Signature

Make full songs with vocals in **your own sound**: trained on music you choose, generated on your iPhone (fully offline) or on your PC.

```
 ┌──────────────── iPhone: Signature app ────────────────┐        ┌──────── PC: Signature Hub ────────┐
 │ Create   on-device ACE-Step 1.5 (Metal) + your styles │        │ ACE-Step 1.5 Studio GUI (Gradio)   │
 │          ── or ── "Make on PC" ───────────────────────┼──LAN──▶│ ACE-Step API  (phone generation)   │
 │ PC tab   upload songs, fix lyrics, train, watch loss ─┼─or────▶│ Side-Step     (style training)     │
 │          download finished styles for offline use ◀──┼Tailscale│ one GPU job at a time, auto-swaps  │
 └───────────────────────────────────────────────────────┘        └────────────────────────────────────┘
```

Built on [ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5), [acestep.cpp](https://github.com/ServeurpersoCom/acestep.cpp) (on-device engine) and [Side-Step](https://github.com/koda-dernet/Side-Step) (training tuned for 12 GB GPUs).

---

## PC: Signature Hub

Standalone; no Pinokio needed. Requires Windows 10/11 (or Linux), an NVIDIA GPU (12 GB+, e.g. RTX 3080 Ti), [git](https://git-scm.com/download/win), and about 25 GB of disk.

1. Download this repo (green **Code → Download ZIP**, or `git clone`), and open the `pc` folder.
2. Double-click **`install.bat`**. It installs everything into `pc\runtime`:
   - `uv`
   - ACE-Step 1.5 and its models (about 10 GB)
   - Side-Step
   - the Hub

   Run it as administrator to add the firewall rule automatically, or click **Allow** when Windows asks on first start.
3. Double-click **`start.bat`**. The Hub dashboard opens at `http://localhost:8790`.
4. Optional, experimental: double-click **`install-yue2.bat`** to add YuE2 (audio.cpp v0.9.2, CUDA 12.4, plus the YuE2-3B Q8 GGUF; about 5 GB). Use `install-yue2.bat q4` on 8 GB cards. YuE2 then appears as an engine in the app.

### The dashboard

| Section | What it shows or does |
|---|---|
| Engine | Switch between **Phone server** (ACE-Step API, used by the app), **Studio GUI** (the full ACE-Step 1.5 web UI at `http://localhost:7860`, the same one Pinokio launches) and **Off**. Only one runs at a time so they fit in 12 GB of VRAM. |
| Pair your iPhone | QR codes for each Wi-Fi and Tailscale address. |
| Training | The current job: step, epoch, loss chart and logs. |
| Styles | Trained styles, with `.safetensors` downloads. |

Training pauses the engine and brings it back when it's done.

The Studio is also reachable from the phone's browser on your network. Log in with user `signature` and your pairing token as the password.

### Remote access with Tailscale
Install [Tailscale](https://tailscale.com) on the PC and the iPhone with the same account. The dashboard then shows a Tailscale QR code that works from anywhere. The Hub only accepts requests carrying your pairing token. **New token** on the dashboard un-pairs every phone.

---

## iPhone: Signature app

### Install
Every push to `main` builds an unsigned IPA through GitHub Actions (**Actions → Build IPA → Artifacts**). Sideload it with SideStore or AltStore. Tagging `v1.0` also attaches the IPA to a Release.

### Pair with your PC
Point the iPhone **Camera** at the QR code on the Hub dashboard and tap the link. The PC tab connects. You can also enter the address and token manually in the PC tab.

### Train your sound (from the phone)
1. Open **PC tab → New training set**. Its name is your trigger word, for example `anchstyle`.
2. Describe the sound, then **Add songs with vocals** and **Add instrumentals** from Files. Use 10–20 or more tracks you own the rights to.
3. **Transcribe lyrics on the PC** runs Whisper with Demucs vocal isolation. Tap each song to fix lyrics and add `[Verse]` / `[Chorus]` tags.
4. **Train style.** The defaults (rank 32, 800 epochs, 8-bit AdamW, encoder offload, 60 s chunks) fit a 12 GB card and take a few hours. You can close the app; the PC tab shows epoch, loss and the log when you come back.
5. When it's done, tap **Get** under *Styles on the PC* to copy the style to the phone.

### Make songs
On **Create**, choose where to make the song:
- **This device**: fully offline. Uses the base model or any style you downloaded. Needs about 3.3 GB of models (Models tab), which download once.
- **Your PC**: faster and allows longer songs (up to 8 minutes). Uses the styles stored on the PC.

Put the trigger word first in your prompt; the **Insert trigger** button does this. Songs are saved to the Library and to **Files → Signature → Songs**.

### Sound controls
Under **Sound** on Create: Weirdness (songwriter temperature / top-p), Style influence (songwriter CFG; DiT CFG on SFT/Base), Clarity (DCW wavelet correction on Turbo models), Texture (Smooth = Euler, Organic = SDE, Crisp = DPM++ 3M) and Quality (step count). 50% everywhere matches the official ACE-Step 1.5 defaults, including DCW `double` 0.05 / 0.02 on Turbo.

### YuE2 (experimental)
Pick **YuE2** under Model → Engine. It sings your lyrics (use `[verse]` / `[chorus]` sections) in the style you describe, with optional melody / full-score planning. It runs on the paired PC after `install-yue2.bat`, or on the device when the build includes `AudioCpp.framework` (iOS Q4 model, 2.6 GB download; needs about 4.3 GB of memory while running, so iPads with 16 GB are the safe bet). YuE2-3B is licensed CC BY-NC 4.0.

### On-device limits
The app reads how much memory iOS gives it and caps song length to match: 4:00 at 4.5 GB or more, 2:30 at 3–4.5 GB, 1:00 below that. The IPA requests Apple's `increased-memory-limit` entitlement. A free Apple ID may not be allowed it when SideStore re-signs the app, in which case the cap adjusts on its own.

---

## Repo layout
```
pc/
  install.bat / start.bat     (install.sh / start.sh on Linux)
  hub/signature_hub/          FastAPI Hub: supervisor, generation proxy, datasets, Side-Step training, dashboard
ios/
  Signature/                  SwiftUI app (on-device engine + PC remote)
  engine/                     C bridge over acestep.cpp
  scripts/build-engine.sh     builds AceEngine.xcframework (Metal)
  scripts/build-audiocpp.sh   builds AudioCpp.framework (audio.cpp C API, YuE2 only, Metal)
  project.yml                 XcodeGen spec
.github/workflows/build-ipa.yml
```

### Hub API (for scripting)
Every call needs `Authorization: Bearer <token>`.

| Endpoint | Purpose |
|---|---|
| `GET /api/status` | Engine mode and state, GPU, current training job |
| `POST /api/mode` | Switch modes: `{"mode": "api"\|"studio"\|"idle"}` |
| `POST /api/generate`, `GET /api/jobs/{id}`, `GET /api/jobs/{id}/audio` | Generate a song and download it |
| `GET/POST /api/datasets`, `POST /api/datasets/{name}/songs` (multipart), `PUT /api/datasets/{name}/songs/{id}` | Training sets, uploads and lyric edits |
| `POST /api/train` (`kind`: `label` or `train`), `GET /api/train`, `POST /api/train/cancel` | Run, watch and stop training |
| `GET /api/styles`, `GET /api/styles/{name}/file` | List styles and download a `.safetensors` |

## Licenses
Signature's own code is yours. Third-party pieces:
- ACE-Step 1.5: MIT and Apache-2.0
- acestep.cpp and ggml: MIT
- Side-Step: CC BY-NC-SA 4.0 (free for personal use; commercial use needs the author's permission)
- audio.cpp: Apache-2.0. YuE2-3B weights: CC BY-NC 4.0 (non-commercial)

Only train on music you own or have permission to use.
