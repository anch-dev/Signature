# Memory budgets per platform

Every OS limits an app's memory differently, so model recommendations, the
"Fits / Tight / Slow mode / Too big" badges and the engine's out-of-memory
guard all come from one function in the shared engine:
`ace_memory_budget(use_cpu)` in `ios/engine/src/ace_bridge.cpp`.
iOS, Android and desktop front ends call it (Swift directly, Kotlin via JNI)
instead of keeping their own tables.

budget = min(live headroom + own footprint, platform ceiling)

| Platform | Live headroom | Ceiling (8 GB device) | Why |
|---|---|---|---|
| iOS | `os_proc_available_memory()` | 5.5 GB (4 GB: 2.2, 6 GB: 3.3, 12 GB: 7.5) | Hard per-app jetsam limit, even with increased-memory-limit |
| Android | `/proc/meminfo` MemAvailable | 3.5 GB (4 GB: 1.5, 6 GB: 2.5, 12 GB: 5.5, 16 GB: 8) | No fixed cap; system + resident apps keep ~half, LMK kills past that |
| macOS | free + inactive + purgeable pages | 66% of RAM | Unified memory, Metal working-set limit |
| Windows / Linux, GPU | free VRAM × 0.92 | — | Discrete GPU: the model must fit in VRAM; RAM is the streaming tier |
| Windows / Linux, CPU | available physical RAM | 75% of RAM | Leave room for the OS |

Need per model = file size + 0.9 GB working (0.5 GB Lite); streamed music
model = 12% of file + working. Only one model is resident at a time.
