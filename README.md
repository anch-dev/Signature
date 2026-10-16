# Signature

Make full songs with vocals **on your iPhone, fully offline**, in a style trained on music you choose.

Signature has two parts:

| Part | Runs on | What it does |
|---|---|---|
| `trainer/` | Windows PC with an NVIDIA GPU (12 GB+ VRAM) | Learns your sound from your songs and exports a small style file (`.safetensors`) |
| `ios/` | iPhone with 8 GB+ RAM | Runs ACE-Step 1.5 locally, loads your style file, and turns a style prompt + lyrics into a 48 kHz stereo song |

The base model is [ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5) (open source, trained on licensed and royalty-free data). On the phone it runs through [acestep.cpp](https://github.com/ServeurpersoCom/acestep.cpp) on Metal. Training uses [Side-Step](https://github.com/koda-dernet/Side-Step).

---

## 1. Train your style (PC)

You need Windows, an NVIDIA GPU (tested target: RTX 3080 Ti, 12 GB), git, and about 20 GB of free disk.

1. **Install the tools (once).** In PowerShell, from the `trainer` folder:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1
   ```
   When Side-Step's installer asks about checkpoints, say **yes to turbo**. The phone runs turbo, so the style has to be trained on turbo.

2. **Collect your songs.** Use 10–20 or more tracks you own the rights to:
   ```
   D:\my_songs\
     vocals\          songs with singing
     instrumentals\   beats, no vocals
     style.txt        optional: one line describing the sound, e.g.
                      "melodic trap, 808s, airy pads, auto-tuned male vocal"
   ```

3. **Train.** Pick a trigger word: lowercase, no spaces, something that isn't a real word.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\train.ps1 -Songs D:\my_songs -Trigger anchstyle
   ```
   The script then:
   - transcribes lyrics with Whisper, using Demucs to isolate the vocals first;
   - pauses so you can fix the lyric `.txt` files next to each song;
   - detects BPM and key;
   - trains (rank-32 LoRA, 8-bit AdamW, encoder offload, 60 s chunks, which fits in 12 GB);
   - writes `anchstyle.safetensors` next to the `trainer` folder.

   Expect a few hours for 800 epochs on a 3080 Ti. To watch progress, run this from the `Side-Step` folder:
   `uv run tensorboard --logdir ..\work\anchstyle\lora\runs`

   Useful options:
   - `-Epochs 500` gives a lighter style.
   - `-Rank 16` uses less VRAM.
   - `-Language en` skips language detection.
   - `-SkipLyrics` keeps the lyric files you already edited.
   - `-Fresh` re-preprocesses after you change songs.

4. **Send it to your phone.** AirDrop the `.safetensors` file (or put it in iCloud Drive) and open it with Signature.

### Tips
- Put the trigger word first in your style prompt. The app's "Insert trigger" button does this for you.
- If outputs sound like near-copies of your training songs, use fewer epochs, lower the strength slider, or add more songs.
- If the style barely shows up, raise strength toward 1.3 or train more epochs.

---

## 2. Build the iPhone app (GitHub Actions, no Mac needed)

Every push to `main` runs **Actions → Build IPA** on a macOS runner. The run:
1. compiles acestep.cpp + ggml for iOS arm64 with Metal (cached after the first run, which takes about 10 minutes);
2. generates the Xcode project with XcodeGen and builds it unsigned;
3. uploads **`Signature.ipa`** as a run artifact. Pushing a tag like `v1.0` also attaches it to a GitHub Release.

Install with **SideStore or AltStore**: download the artifact zip, extract `Signature.ipa`, and open it in SideStore.

### First launch
1. Go to the **Models** tab, then **Download**. This is about 3.3 GB on Wi-Fi, once. "High quality" uses a Q8 music model (4.4 GB total).
2. Import your style file (or open it from AirDrop).
3. On the **Create** tab, pick your style, write a style prompt and lyrics, and tap **Generate**.

A 1–2 minute song takes a few minutes on a recent Pro iPhone. Keep the app in the foreground; it disables auto-lock while working. Songs are saved to **Files → On My iPhone → Signature → Songs**.

### Memory
Only one network is loaded at a time (songwriter, then text encoder, then music model, then audio decoder), so peak use is roughly the largest model plus its working memory. Real numbers per device are still to be measured. The app reads how much memory iOS gives it and caps song length to match:

| Memory available to the app | Longest song |
|---|---|
| 4.5 GB or more | 4:00 |
| 3.0–4.5 GB | 2:30 |
| less than 3.0 GB | 1:00 |

The IPA requests Apple's `increased-memory-limit` entitlement. A free Apple ID may not be allowed that entitlement when SideStore re-signs the app. If so, the app still runs with the default limit, and the length cap above adjusts on its own.

---

## Repo layout
```
trainer/                 PC side: setup.ps1, train.ps1, prep_dataset.py
ios/
  engine/                C bridge over acestep.cpp + CMake (also builds a desktop smoke test)
  scripts/build-engine.sh  builds Frameworks/AceEngine.xcframework
  Signature/             SwiftUI app
  project.yml            XcodeGen spec
.github/workflows/build-ipa.yml
```

## Licenses
Signature's own code is yours. Third-party pieces:
- ACE-Step 1.5 weights and code: MIT/Apache-2.0
- acestep.cpp and ggml: MIT
- Side-Step: CC BY-NC-SA 4.0 (free for personal use; commercial use needs the author's permission)

Only train on music you own or have permission to use.
