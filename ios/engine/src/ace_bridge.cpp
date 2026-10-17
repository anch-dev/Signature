// ace_bridge.cpp - drives acestep.cpp's LM -> DiT -> VAE pipeline for the app.
//
// Mirrors tools/ace-lm.cpp + tools/ace-synth.cpp, minus files and CLI. The
// pipelines only expose a cancel hook (polled once per LM token, DiT step and
// VAE tile), so progress - and peak memory - are sampled from those polls.

#include "ace_bridge.h"

#include "audio-io.h"
#include "backend.h"
#include "model-store.h"
#include "pipeline-lm.h"
#include "pipeline-synth.h"
#include "request.h"
#include "task-types.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#if defined(__APPLE__)
#    include <TargetConditionals.h>
#    include <mach/mach.h>
#    if TARGET_OS_IPHONE
#        include <os/proc.h>
#    endif
#elif defined(__linux__)
#    include <unistd.h>
#endif

struct ace_engine {
    ModelStore *       store = nullptr;
    std::mutex         busy;  // one song at a time
    ace_engine_options opts{ 1, 0, 0, 0 };
};

extern "C" uint64_t ace_memory_footprint(void) {
#if defined(__APPLE__)
    task_vm_info_data_t    info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS) {
        return (uint64_t) info.phys_footprint;
    }
    return 0;
#elif defined(__linux__)
    long  pages = 0, resident = 0;
    FILE * f    = fopen("/proc/self/statm", "r");
    if (!f) {
        return 0;
    }
    if (fscanf(f, "%ld %ld", &pages, &resident) != 2) {
        resident = 0;
    }
    fclose(f);
    return (uint64_t) resident * (uint64_t) sysconf(_SC_PAGESIZE);
#else
    return 0;
#endif
}

namespace {

struct Peaks {
    uint64_t v[ACE_STAGE_COUNT] = { 0 };
    void     sample(ace_stage s) {
        uint64_t now = ace_memory_footprint();
        if (now > v[s]) {
            v[s] = now;
        }
    }
};

struct Tick {
    ace_progress_fn fn;
    void *          user;
    ace_stage       stage;
    float           expected;  // estimated number of polls for this stage
    Peaks *         peaks;
    float           count     = 0;
    bool            cancelled = false;
};

bool tick_cb(void * p) {
    Tick * t = static_cast<Tick *>(p);
    t->count += 1.0f;
    t->peaks->sample(t->stage);
    float f = t->expected > 0 ? std::min(t->count / t->expected, 0.99f) : 0.0f;
    if (t->fn && t->fn(t->user, t->stage, f) != 0) {
        t->cancelled = true;
    }
    return t->cancelled;
}

void report(ace_progress_fn fn, void * user, ace_stage s, float f, bool * cancelled, Peaks * peaks) {
    peaks->sample(s);
    if (fn && fn(user, s, f) != 0) {
        *cancelled = true;
    }
}

double now_s() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

struct Verbose {
    bool   on = false;
    double t0 = now_s(), stage_t = now_s();
    void   stage(const char * name) {
        if (!on) {
            return;
        }
        double t = now_s();
        fprintf(stderr, "[Signature] %-11s done in %6.2fs (total %6.2fs), memory %.0f MB\n", name, t - stage_t, t - t0,
                (double) ace_memory_footprint() / 1048576.0);
        stage_t = t;
    }
};

// ---- prompt enhancement: add to the user's words, never replace them ----

std::string lower(std::string s) {
    for (auto & ch : s) {
        ch = (char) tolower((unsigned char) ch);
    }
    return s;
}

std::vector<std::string> keywords(const std::string & text) {
    static const char * stop[] = { "the", "and", "with", "song", "music", "about", "for", "that", "this", "track",
                                   "from", "into", "very", "some", "style", "like", "feat", "vibe", "sound" };
    std::vector<std::string> out;
    std::string              w;
    auto                     flush = [&]() {
        if (w.size() >= 3) {
            bool s = false;
            for (const char * x : stop) {
                s |= w == x;
            }
            if (!s) {
                out.push_back(w);
            }
        }
        w.clear();
    };
    for (char ch : lower(text)) {
        if (isalnum((unsigned char) ch) || ch == '&') {
            w += ch;
        } else {
            flush();
        }
    }
    flush();
    return out;
}

// Relevant = the enhanced text keeps at least one of the user's key words
// (a 3+ letter non-filler word). Catches the songwriter drifting off-topic.
bool relevant(const std::string & user, const std::string & enhanced) {
    auto uk = keywords(user);
    if (uk.empty()) {
        return true;
    }
    std::string e = lower(enhanced);
    for (const auto & k : uk) {
        if (e.find(k) != std::string::npos) {
            return true;
        }
    }
    return false;
}

// True when lyrics contain sung words, not only [Section] tags.
bool has_words(const std::string & lyrics) {
    bool in_tag = false;
    int  letters = 0;
    for (char ch : lyrics) {
        if (ch == '[') {
            in_tag = true;
        } else if (ch == ']') {
            in_tag = false;
        } else if (!in_tag && isalpha((unsigned char) ch)) {
            letters++;
        }
    }
    return letters >= 12;
}

std::string merge_caption(const std::string & user, const std::string & enhanced) {
    std::string u = user, en = enhanced;
    while (!en.empty() && isspace((unsigned char) en.back())) {
        en.pop_back();
    }
    if (en.empty() || lower(en) == lower(u) || !relevant(u, en)) {
        return u;
    }
    if (lower(en).find(lower(u)) != std::string::npos && lower(en).rfind(lower(u), 0) == 0) {
        return en.substr(0, 900);  // enhancement already starts with the user's exact words
    }
    std::string m = u;
    while (!m.empty() && (m.back() == '.' || m.back() == ',' || isspace((unsigned char) m.back()))) {
        m.pop_back();
    }
    return (m + ". " + en).substr(0, 900);
}

// Bytes the OS will still let this process allocate (iOS); 0 = unknown.
uint64_t available_memory() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return (uint64_t) os_proc_available_memory();
#else
    return 0;
#endif
}

uint64_t file_size(const char * path) {
    FILE * f = path ? fopen(path, "rb") : nullptr;
    if (!f) {
        return 0;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fclose(f);
    return n > 0 ? (uint64_t) n : 0;
}

// Refuse to load a model that clearly can't fit, instead of being killed by iOS.
// Mapped weights are file-backed (reclaimable), so only part of the file counts.
uint64_t module_need(const char * path, bool low, bool streamed);
bool     fits_need(uint64_t need, char * err, int err_len, const char * what, const char * hint);

void set_err(char * err, int len, const char * msg) {
    if (err && len > 0) {
        snprintf(err, (size_t) len, "%s", msg);
    }
}

bool empty(const char * s) { return s == nullptr || s[0] == '\0'; }

void copy_str(char * dst, size_t cap, const std::string & s) {
    snprintf(dst, cap, "%s", s.c_str());
}

// Rough resident need of a module: weights (a mapped file still counts once
// the GPU wires it) plus working memory for activations, KV cache and tiles.
uint64_t module_need(const char * path, bool low, bool streamed) {
    uint64_t size    = file_size(path);
    uint64_t working = (low ? 500ull : 900ull) * 1048576ull;
    double   frac    = streamed ? 0.12 : 1.0;  // streamed: embeddings + one layer
    return (uint64_t) ((double) size * frac) + working;
}

bool fits_need(uint64_t need, char * err, int err_len, const char * what, const char * hint) {
    uint64_t avail = available_memory();
    if (avail == 0 || need <= avail) {
        return true;
    }
    if (err && err_len > 0) {
        snprintf(err, (size_t) err_len, "Not enough memory for the %s (needs about %.1f GB, %.1f GB free). %s", what,
                 (double) need / 1073741824.0, (double) avail / 1073741824.0, hint);
    }
    fprintf(stderr, "[Signature] memory guard: %s needs ~%.0f MB, %.0f MB available\n", what,
            (double) need / 1048576.0, (double) avail / 1048576.0);
    return false;
}

}  // namespace

extern "C" {

ace_engine * ace_engine_create(void) {
#if defined(__APPLE__)
    // Metal residency sets pin every buffer (including memory-mapped model
    // files) and keep them alive for minutes after release. On a phone that
    // defeats both mapping and one-model-at-a-time unloading, so turn them off.
    setenv("GGML_METAL_NO_RESIDENCY", "1", 1);
#endif
    ace_engine * e = new ace_engine();
    e->store       = store_create(EVICT_STRICT);
    if (!e->store) {
        delete e;
        return nullptr;
    }
    g_wctx_zero_copy = e->opts.zero_copy != 0;
    g_wctx_no_fuse   = g_wctx_zero_copy;
    return e;
}

void ace_engine_free(ace_engine * e) {
    if (!e) {
        return;
    }
    store_free(e->store);
    delete e;
}

void ace_engine_set_options(ace_engine * e, const ace_engine_options * o) {
    if (!e || !o) {
        return;
    }
    std::lock_guard<std::mutex> lock(e->busy);
    e->opts          = *o;
    g_wctx_zero_copy = o->zero_copy != 0;
    g_wctx_no_fuse   = g_wctx_zero_copy;  // fused weights can't be mapped from the file
    // Takes effect the next time a model loads (strict eviction reloads per stage).
    if (o->use_cpu) {
        backend_set_device("CPU");
    } else {
        g_backend_device = NULL;
    }
}

int ace_engine_generate(ace_engine *             e,
                        const ace_model_paths *  m,
                        const ace_song_request * r,
                        const char *             out_wav_path,
                        ace_progress_fn          progress,
                        void *                   user,
                        ace_song_info *          info_out,
                        char *                   err,
                        int                      err_len) {
    if (!e || !m || !r || empty(out_wav_path)) {
        set_err(err, err_len, "missing arguments");
        return -1;
    }
    if (empty(m->text_enc_path) || empty(m->dit_path) || empty(m->vae_path)) {
        set_err(err, err_len, "text encoder, music model and audio decoder are required");
        return -1;
    }
    std::lock_guard<std::mutex> lock(e->busy);
    const bool  low  = e->opts.low_memory != 0;
    const float maxd = low ? 120.0f : 240.0f;
    const int   task = empty(r->src_audio_path) ? ACE_TASK_NEW : r->task;

    // Source audio for cover / repaint, decoded and resampled to 48 kHz stereo.
    std::vector<float> src;  // interleaved
    int                src_len = 0;
    if (task != ACE_TASK_NEW) {
        int     T      = 0;
        float * planar = audio_read_48k(r->src_audio_path, &T);
        if (!planar || T <= 0) {
            free(planar);
            set_err(err, err_len, "could not read the source audio (use WAV or MP3)");
            return -1;
        }
        // Planar layout: left channel [0, T), right channel [T, 2T). Keep at most maxd seconds.
        const int full = T;
        const int keep = std::min(T, (int) (maxd * 48000.0f));
        src.resize((size_t) keep * 2);
        for (int i = 0; i < keep; i++) {
            src[(size_t) i * 2]     = planar[i];
            src[(size_t) i * 2 + 1] = planar[(size_t) full + (size_t) i];
        }
        T = keep;
        free(planar);
        src_len = T;
    }
    // Covers follow the source's structure, so the songwriter's code plan is skipped.
    const bool  lm       = !empty(m->lm_path) && task == ACE_TASK_NEW;
    const float src_secs = (float) src_len / 48000.0f;
    const float duration = task != ACE_TASK_NEW ? std::clamp(src_secs, 1.0f, maxd)
                                                : std::clamp(r->duration > 0 ? r->duration : 60.0f, 10.0f, maxd);

    Peaks   peaks;
    Verbose vb;
    vb.on = e->opts.verbose != 0;
    if (vb.on) {
        fprintf(stderr, "[Signature] ---- new job ----\n");
        fprintf(stderr, "[Signature] options: zero_copy=%d low_memory=%d cpu=%d stream_layers=%d\n", e->opts.zero_copy,
                e->opts.low_memory, e->opts.use_cpu, e->opts.stream_layers);
        fprintf(stderr, "[Signature] models: lm=%s\n[Signature]         text=%s\n[Signature]         dit=%s\n"
                        "[Signature]         vae=%s\n[Signature]         adapter=%s (scale %.2f)\n",
                m->lm_path ? m->lm_path : "(none)", m->text_enc_path, m->dit_path, m->vae_path,
                m->adapter_path ? m->adapter_path : "(none)", m->adapter_scale);
        fprintf(stderr, "[Signature] task=%d src=%s memory at start %.0f MB\n", task,
                r->src_audio_path ? r->src_audio_path : "(none)", (double) ace_memory_footprint() / 1048576.0);
    }

    AceRequest req;
    request_init(&req);
    req.caption = r->caption ? r->caption : "";
    // Empty lyrics + songwriter = "simple mode": the LM writes the lyrics.
    req.lyrics   = empty(r->lyrics) ? (lm ? "" : "[Instrumental]") : r->lyrics;
    req.duration = duration;
    req.bpm      = r->bpm > 0 ? r->bpm : 0;
    if (!empty(r->vocal_language)) {
        req.vocal_language = r->vocal_language;
    }
    req.seed            = r->seed;
    req.inference_steps = r->inference_steps > 0 ? r->inference_steps : 0;
    // Your prompt is the style. The songwriter may write lyrics and pick BPM/key,
    // but must not rewrite the caption (it otherwise replaces short prompts like
    // "hip hop" with its own, unrelated description).
    req.use_cot_caption = false;
    req.task_type       = task == ACE_TASK_COVER ? TASK_COVER : task == ACE_TASK_REPAINT ? TASK_REPAINT : TASK_TEXT2MUSIC;
    if (task == ACE_TASK_COVER) {
        req.audio_cover_strength = r->cover_strength > 0 ? std::min(r->cover_strength, 1.0f) : 1.0f;
        req.cover_noise_strength = std::clamp(r->cover_noise, 0.0f, 1.0f);
    } else if (task == ACE_TASK_REPAINT) {
        req.repainting_start = std::max(0.0f, r->repaint_start);
        req.repainting_end   = r->repaint_end;
    }
    if (task != ACE_TASK_NEW && req.lyrics.empty()) {
        req.lyrics = "[Instrumental]";
    }
    req.lm_mode         = LM_MODE_NAME_GENERATE;
    request_resolve_seed(&req);
    request_resolve_lm_seed(&req);

    bool cancelled = false;
    peaks.sample(ACE_STAGE_SONGWRITER);
    if (vb.on) {
        request_dump(&req, stderr);
    }

    // ---- 1. Songwriter (5Hz LM): lyrics if empty, BPM/key/structure, audio code plan.
    AceRequest planned = req;
    if (lm) {
        AceLmParams lp;
        ace_lm_default_params(&lp);
        lp.model_path = m->lm_path;
        lp.max_batch  = 1;
        // KV cache grows with max_seq: 4096 tokens covers ~4 min songs; 2048 covers ~2 min.
        lp.max_seq = low ? 2048 : 4096;
        if (low) {
            lp.use_batch_cfg = false;  // run cond/uncond one after another: half the activations
        }

        if (!fits_need(module_need(m->lm_path, low, false), err, err_len, "songwriter",
                       "Pick the smaller songwriter, turn the songwriter off, or close other apps.")) {
            return -1;
        }
        AceLm * lmctx = ace_lm_load(e->store, &lp);
        if (!lmctx) {
            set_err(err, err_len, "could not load the songwriter model");
            return -1;
        }
        // One poll per generated token: ~5 audio codes per second of music,
        // a few hundred tokens of metadata, plus lyrics when it writes them.
        const bool enhance  = r->enhance_prompt != 0 && !req.caption.empty();
        float      expected = duration * 5.0f + 350.0f + (req.lyrics.empty() ? duration * 3.0f : 0.0f) +
                         (enhance ? 250.0f : 0.0f);
        Tick       t{ progress, user, ACE_STAGE_SONGWRITER, expected, &peaks };

        // Pass 1 (optional): enhance. FORMAT mode expands caption (and writes
        // lyrics if empty); we keep the user's words first and drop drift.
        if (enhance) {
            AceRequest fmt  = req;
            fmt.lm_mode     = LM_MODE_NAME_FORMAT;
            fmt.use_cot_caption = true;
            std::vector<AceRequest> fo(1);
            int frc = ace_lm_generate(lmctx, &fmt, 1, fo.data(), nullptr, nullptr, tick_cb, &t, LM_MODE_FORMAT);
            if (t.cancelled) {
                ace_lm_free(lmctx);
                return 1;
            }
            if (frc == 0) {
                std::string merged = merge_caption(req.caption, fo[0].caption);
                if (vb.on) {
                    fprintf(stderr, "[Signature] enhance: user=\"%s\"\n[Signature] enhance: lm=\"%s\"\n[Signature] enhance: %s\n",
                            req.caption.c_str(), fo[0].caption.c_str(),
                            merged == req.caption ? "kept user prompt only (no relevant additions)" : "merged");
                }
                const bool on_topic = relevant(req.caption, fo[0].caption);
                req.caption         = merged;
                // Only reuse the format pass's lyrics when it stayed on topic and
                // actually wrote words (not just [Section] tags).
                if (req.lyrics.empty() && on_topic && has_words(fo[0].lyrics)) {
                    req.lyrics = fo[0].lyrics;
                } else if (vb.on && req.lyrics.empty()) {
                    fprintf(stderr, "[Signature] enhance: discarded its lyrics (%s)\n",
                            on_topic ? "no words" : "off topic");
                }
            } else if (vb.on) {
                fprintf(stderr, "[Signature] enhance: format pass failed, using prompt as typed\n");
            }
        }

        // Pass 2: plan the song with the (locked) caption.
        std::vector<AceRequest> out(1);
        int rc = ace_lm_generate(lmctx, &req, 1, out.data(), nullptr, nullptr, tick_cb, &t, LM_MODE_GENERATE);
        ace_lm_free(lmctx);
        if (t.cancelled) {
            return 1;
        }
        if (rc != 0) {
            set_err(err, err_len, "songwriter failed (try a shorter song or simpler lyrics)");
            return -1;
        }
        planned                 = out[0];
        planned.seed            = req.seed;
        planned.duration        = duration;
        planned.inference_steps = req.inference_steps;
        if (planned.lyrics.empty()) {
            planned.lyrics = "[Instrumental]";
        }
    }
    report(progress, user, ACE_STAGE_SONGWRITER, 1.0f, &cancelled, &peaks);
    if (cancelled) {
        return 1;
    }
    if (lm) {
        vb.stage("songwriter");
        if (vb.on) {
            fprintf(stderr, "[Signature] songwriter plan: bpm=%d key=%s duration=%.1f codes=%zu chars\n", planned.bpm,
                    planned.keyscale.c_str(), planned.duration, planned.audio_codes.size());
            fprintf(stderr, "[Signature] lyrics used:\n%s\n", planned.lyrics.c_str());
        }
    }

    // ---- 2. Diffusion (DiT, with your adapter merged in at load).
    AceSynthParams sp;
    ace_synth_default_params(&sp);
    sp.text_encoder_path = m->text_enc_path;
    sp.dit_path          = m->dit_path;
    sp.vae_path          = m->vae_path;
    sp.adapter_path      = empty(m->adapter_path) ? nullptr : m->adapter_path;
    sp.adapter_scale     = m->adapter_scale > 0 ? m->adapter_scale : 1.0f;
    if (low) {
        sp.use_batch_cfg = false;
        sp.vae_chunk     = 128;
        sp.vae_overlap   = 32;
    } else {
        // Smaller VAE tiles above ~40 s keep the decode under the jetsam limit on 8 GB phones.
        sp.vae_chunk = duration > 40.0f ? 256 : 512;
    }

    // Layer streaming: forced on, or automatic when the whole model won't fit.
    bool stream = e->opts.stream_layers == 1;
    if (e->opts.stream_layers == 2 && !stream) {
        uint64_t avail = available_memory();
        stream         = avail != 0 && module_need(m->dit_path, low, false) > avail;
        if (stream) {
            fprintf(stderr, "[Signature] music model doesn't fit (%.0f MB free): streaming layers from storage\n",
                    (double) avail / 1048576.0);
        }
    }
    g_wctx_stream = stream;
    if (!fits_need(module_need(m->dit_path, low, stream), err, err_len, "music model",
                   stream ? "Pick a smaller size (Compact) or close other apps."
                          : "Pick a smaller size, turn on Low memory (slow) in Settings, or close other apps.")) {
        g_wctx_stream = false;
        return -1;
    }
    AceSynth * synth = ace_synth_load(e->store, &sp);
    if (!synth) {
        set_err(err, err_len, sp.adapter_path ? "could not load the music model or your style"
                                              : "could not load the music model");
        return -1;
    }

    // Turbo models default to 8 steps, SFT/Base to 50 (read from the model's metadata).
    const DiTMeta * meta  = store_dit_meta(e->store, m->dit_path);
    const int       steps = req.inference_steps > 0 ? req.inference_steps : (meta && !meta->is_turbo ? 50 : 8);
    Tick      dt{ progress, user, ACE_STAGE_DIFFUSION, (float) steps, &peaks };
    report(progress, user, ACE_STAGE_DIFFUSION, 0.0f, &cancelled, &peaks);
    AceSynthJob * job = cancelled ? nullptr
                                  : ace_synth_job_run_dit(synth, &planned, src.empty() ? nullptr : src.data(), src_len,
                                                          nullptr, 0, nullptr, 0, nullptr, 0, 1, tick_cb, &dt);
    peaks.sample(ACE_STAGE_DIFFUSION);
    if (!job) {
        ace_synth_free(synth);
        if (dt.cancelled || cancelled) {
            return 1;
        }
        set_err(err, err_len, "music generation failed (out of memory? try Lite mode or a shorter song)");
        return -1;
    }
    report(progress, user, ACE_STAGE_DIFFUSION, 1.0f, &cancelled, &peaks);
    vb.stage("diffusion");

    // ---- 3. Decode latents to audio. ~25 latent frames per second of music.
    const float latent_frames = duration * 25.0f;
    Tick        vt{ progress, user, ACE_STAGE_DECODE, std::ceil(latent_frames / (float) sp.vae_chunk), &peaks };
    AceAudio    audio{};
    int         vrc = cancelled ? -1 : ace_synth_job_run_vae(synth, job, &audio, tick_cb, &vt);
    peaks.sample(ACE_STAGE_DECODE);
    vb.stage("decode");
    ace_synth_job_free(job);
    ace_synth_free(synth);
    if (cancelled || vt.cancelled) {
        ace_audio_free(&audio);
        return 1;
    }
    if (vrc != 0 || !audio.samples) {
        set_err(err, err_len, "audio decode failed (out of memory? try Lite mode or a shorter song)");
        return -1;
    }

    // ---- 4. Save.
    report(progress, user, ACE_STAGE_SAVING, 0.0f, &cancelled, &peaks);
    bool ok = audio_write(out_wav_path, audio.samples, audio.n_samples, audio.sample_rate, 0, WAV_S16,
                          planned.peak_clip);
    ace_audio_free(&audio);
    if (!ok) {
        set_err(err, err_len, "could not write the audio file");
        return -1;
    }
    report(progress, user, ACE_STAGE_SAVING, 1.0f, &cancelled, &peaks);
    vb.stage("save");
    if (vb.on) {
        fprintf(stderr, "[Signature] peaks MB: songwriter %.0f, diffusion %.0f, decode %.0f, save %.0f\n",
                peaks.v[0] / 1048576.0, peaks.v[1] / 1048576.0, peaks.v[2] / 1048576.0, peaks.v[3] / 1048576.0);
    }

    if (info_out) {
        memset(info_out, 0, sizeof(*info_out));
        info_out->streamed  = stream ? 1 : 0;
        info_out->seed_used = planned.seed;
        info_out->bpm       = planned.bpm;
        info_out->duration  = duration;
        copy_str(info_out->keyscale, sizeof(info_out->keyscale), planned.keyscale);
        copy_str(info_out->caption, sizeof(info_out->caption), planned.caption);
        copy_str(info_out->lyrics, sizeof(info_out->lyrics), planned.lyrics);
        for (int i = 0; i < ACE_STAGE_COUNT; i++) {
            info_out->peak_bytes[i] = peaks.v[i];
        }
        info_out->mapped_ok = g_wctx_zero_copy ? 1 : 0;
    }
    return 0;
}

}  // extern "C"
