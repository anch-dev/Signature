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
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#if defined(__APPLE__)
#    include <mach/mach.h>
#elif defined(__linux__)
#    include <unistd.h>
#endif

struct ace_engine {
    ModelStore *       store = nullptr;
    std::mutex         busy;  // one song at a time
    ace_engine_options opts{ 1, 0, 0 };
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

void set_err(char * err, int len, const char * msg) {
    if (err && len > 0) {
        snprintf(err, (size_t) len, "%s", msg);
    }
}

bool empty(const char * s) { return s == nullptr || s[0] == '\0'; }

void copy_str(char * dst, size_t cap, const std::string & s) {
    snprintf(dst, cap, "%s", s.c_str());
}

}  // namespace

extern "C" {

ace_engine * ace_engine_create(void) {
    ace_engine * e = new ace_engine();
    e->store       = store_create(EVICT_STRICT);
    if (!e->store) {
        delete e;
        return nullptr;
    }
    g_wctx_zero_copy = e->opts.zero_copy != 0;
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
    const bool  lm   = !empty(m->lm_path);
    const float maxd = low ? 120.0f : 240.0f;
    const float duration = std::clamp(r->duration > 0 ? r->duration : 60.0f, 10.0f, maxd);

    Peaks peaks;

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
    req.task_type       = TASK_TEXT2MUSIC;
    req.lm_mode         = LM_MODE_NAME_GENERATE;
    request_resolve_seed(&req);
    request_resolve_lm_seed(&req);

    bool cancelled = false;
    peaks.sample(ACE_STAGE_SONGWRITER);

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

        AceLm * lmctx = ace_lm_load(e->store, &lp);
        if (!lmctx) {
            set_err(err, err_len, "could not load the songwriter model");
            return -1;
        }
        // One poll per generated token: ~5 audio codes per second of music,
        // a few hundred tokens of metadata, plus lyrics when it writes them.
        float expected = duration * 5.0f + 350.0f + (req.lyrics.empty() ? duration * 3.0f : 0.0f);
        Tick  t{ progress, user, ACE_STAGE_SONGWRITER, expected, &peaks };
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
                                  : ace_synth_job_run_dit(synth, &planned, nullptr, 0, nullptr, 0, nullptr, 0,
                                                          nullptr, 0, 1, tick_cb, &dt);
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

    // ---- 3. Decode latents to audio. ~25 latent frames per second of music.
    const float latent_frames = duration * 25.0f;
    Tick        vt{ progress, user, ACE_STAGE_DECODE, std::ceil(latent_frames / (float) sp.vae_chunk), &peaks };
    AceAudio    audio{};
    int         vrc = cancelled ? -1 : ace_synth_job_run_vae(synth, job, &audio, tick_cb, &vt);
    peaks.sample(ACE_STAGE_DECODE);
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

    if (info_out) {
        memset(info_out, 0, sizeof(*info_out));
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
