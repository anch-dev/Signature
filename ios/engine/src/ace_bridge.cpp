// ace_bridge.cpp - drives acestep.cpp's LM -> DiT -> VAE pipeline for the app.
//
// Mirrors tools/ace-lm.cpp + tools/ace-synth.cpp, minus files and CLI. The
// pipelines only expose a cancel hook (polled once per LM token, DiT step and
// VAE tile), so progress is derived by counting those polls.

#include "ace_bridge.h"

#include "audio-io.h"
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

struct ace_engine {
    ModelStore * store = nullptr;
    std::mutex   busy;  // one song at a time
};

namespace {

struct Tick {
    ace_progress_fn fn;
    void *          user;
    ace_stage       stage;
    float           expected;  // estimated number of polls for this stage
    float           count = 0;
    bool            cancelled = false;
};

bool tick_cb(void * p) {
    Tick * t = static_cast<Tick *>(p);
    t->count += 1.0f;
    float f = t->expected > 0 ? std::min(t->count / t->expected, 0.99f) : 0.0f;
    if (t->fn && t->fn(t->user, t->stage, f) != 0) {
        t->cancelled = true;
    }
    return t->cancelled;
}

void report(ace_progress_fn fn, void * user, ace_stage s, float f, bool * cancelled) {
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

}  // namespace

extern "C" {

ace_engine * ace_engine_create(void) {
    ace_engine * e = new ace_engine();
    e->store       = store_create(EVICT_STRICT);
    if (!e->store) {
        delete e;
        return nullptr;
    }
    return e;
}

void ace_engine_free(ace_engine * e) {
    if (!e) {
        return;
    }
    store_free(e->store);
    delete e;
}

uint64_t ace_engine_resident_bytes(const ace_engine * e) {
    return e ? (uint64_t) store_vram_bytes(e->store) : 0;
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
        set_err(err, err_len, "text encoder, DiT and VAE models are required");
        return -1;
    }
    std::lock_guard<std::mutex> lock(e->busy);

    const float duration = std::clamp(r->duration > 0 ? r->duration : 60.0f, 10.0f, 240.0f);

    AceRequest req;
    request_init(&req);
    req.caption  = r->caption ? r->caption : "";
    req.lyrics   = empty(r->lyrics) ? "[Instrumental]" : r->lyrics;
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

    // ---- 1. Songwriter (5Hz LM): fills BPM/key/structure + audio code plan.
    AceRequest planned = req;
    if (!empty(m->lm_path)) {
        AceLmParams lp;
        ace_lm_default_params(&lp);
        lp.model_path = m->lm_path;
        lp.max_batch  = 1;
        lp.max_seq    = 4096;  // halves the KV cache vs the 8192 default; fits ~4 min songs

        AceLm * lm = ace_lm_load(e->store, &lp);
        if (!lm) {
            set_err(err, err_len, "could not load the songwriter model");
            return -1;
        }
        // Polls once per generated token: ~5 audio codes per second of music
        // plus a few hundred tokens of chain-of-thought metadata.
        Tick t{ progress, user, ACE_STAGE_SONGWRITER, duration * 5.0f + 350.0f };
        std::vector<AceRequest> out(1);
        int rc = ace_lm_generate(lm, &req, 1, out.data(), nullptr, nullptr, tick_cb, &t, LM_MODE_GENERATE);
        ace_lm_free(lm);
        if (t.cancelled) {
            return 1;
        }
        if (rc != 0) {
            set_err(err, err_len, "songwriter failed (try a shorter song or simpler lyrics)");
            return -1;
        }
        planned          = out[0];
        planned.seed     = req.seed;
        planned.duration = duration;
    }
    report(progress, user, ACE_STAGE_SONGWRITER, 1.0f, &cancelled);
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
    // Smaller VAE tiles above ~40 s keep the decode under the jetsam limit on 8 GB phones.
    sp.vae_chunk = duration > 40.0f ? 256 : 512;

    AceSynth * synth = ace_synth_load(e->store, &sp);
    if (!synth) {
        set_err(err, err_len, sp.adapter_path ? "could not load the diffusion model or your style adapter"
                                              : "could not load the diffusion model");
        return -1;
    }

    const int steps = planned.inference_steps > 0 ? planned.inference_steps : 8;
    Tick      dt{ progress, user, ACE_STAGE_DIFFUSION, (float) steps };
    AceSynthJob * job = ace_synth_job_run_dit(synth, &planned, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, 0, 1,
                                              tick_cb, &dt);
    if (!job) {
        ace_synth_free(synth);
        if (dt.cancelled) {
            return 1;
        }
        set_err(err, err_len, "diffusion failed");
        return -1;
    }
    report(progress, user, ACE_STAGE_DIFFUSION, 1.0f, &cancelled);

    // ---- 3. Decode latents to audio. ~25 latent frames per second of music.
    const float latent_frames = duration * 25.0f;
    Tick        vt{ progress, user, ACE_STAGE_DECODE, std::ceil(latent_frames / (float) sp.vae_chunk) };
    AceAudio    audio{};
    int         vrc = cancelled ? -1 : ace_synth_job_run_vae(synth, job, &audio, tick_cb, &vt);
    ace_synth_job_free(job);
    ace_synth_free(synth);
    if (cancelled || vt.cancelled) {
        ace_audio_free(&audio);
        return 1;
    }
    if (vrc != 0 || !audio.samples) {
        set_err(err, err_len, "audio decode failed (out of memory? try a shorter song)");
        return -1;
    }

    // ---- 4. Save.
    report(progress, user, ACE_STAGE_SAVING, 0.0f, &cancelled);
    bool ok = audio_write(out_wav_path, audio.samples, audio.n_samples, audio.sample_rate, 0, WAV_S16,
                          planned.peak_clip);
    ace_audio_free(&audio);
    if (!ok) {
        set_err(err, err_len, "could not write the WAV file");
        return -1;
    }
    report(progress, user, ACE_STAGE_SAVING, 1.0f, &cancelled);

    if (info_out) {
        info_out->seed_used = planned.seed;
        info_out->bpm       = planned.bpm;
        info_out->duration  = duration;
        snprintf(info_out->keyscale, sizeof(info_out->keyscale), "%s", planned.keyscale.c_str());
    }
    return 0;
}

}  // extern "C"
