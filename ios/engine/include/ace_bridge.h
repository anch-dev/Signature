// ace_bridge.h - plain C interface over acestep.cpp for Swift.
//
// One engine owns one ModelStore in EVICT_STRICT mode: only one network
// (LM, text encoder, DiT or VAE) is resident at a time, which is what keeps
// a full song under the ~6 GB per-app memory ceiling on 8 GB+ iPhones.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ace_engine ace_engine;

typedef enum {
    ACE_STAGE_SONGWRITER = 0,  // 5Hz LM: metadata + audio code plan
    ACE_STAGE_DIFFUSION  = 1,  // DiT denoising
    ACE_STAGE_DECODE     = 2,  // VAE decode to audio
    ACE_STAGE_SAVING     = 3,  // writing the WAV
} ace_stage;

// fraction is 0..1 within the stage (estimated for the songwriter stage).
// Called on the generating thread. Return nonzero to cancel.
typedef int (*ace_progress_fn)(void * user, ace_stage stage, float fraction);

typedef struct {
    const char * lm_path;        // acestep-5Hz-lm-*.gguf  (NULL = skip songwriter)
    const char * text_enc_path;  // Qwen3-Embedding-*.gguf (required)
    const char * dit_path;       // acestep-v15-turbo-*.gguf (required)
    const char * vae_path;       // vae-*.gguf (required)
    const char * adapter_path;   // your trained .safetensors (NULL = none)
    float        adapter_scale;  // 1.0 = full strength
} ace_model_paths;

typedef struct {
    const char * caption;         // style prompt, include your trigger word
    const char * lyrics;          // "[Instrumental]" for no vocals
    const char * vocal_language;  // "en", "es", ... or NULL/"" for auto
    float        duration;        // seconds, 10..240
    int          bpm;             // 0 = let the songwriter decide
    int64_t      seed;            // -1 = random
    int          inference_steps; // 0 = model default (8 for turbo)
} ace_song_request;

typedef struct {
    int64_t seed_used;
    int     bpm;
    char    keyscale[32];
    float   duration;
} ace_song_info;

ace_engine * ace_engine_create(void);
void         ace_engine_free(ace_engine * e);

// Generates one song and writes a 48 kHz 16-bit stereo WAV to out_wav_path.
// Blocking; call from a background thread. Returns 0 on success, 1 when
// cancelled, -1 on error (message in err).
int ace_engine_generate(ace_engine *             e,
                        const ace_model_paths *  models,
                        const ace_song_request * req,
                        const char *             out_wav_path,
                        ace_progress_fn          progress,
                        void *                   user,
                        ace_song_info *          info_out,
                        char *                   err,
                        int                      err_len);

// Bytes of model weights currently resident (diagnostics).
uint64_t ace_engine_resident_bytes(const ace_engine * e);

#ifdef __cplusplus
}
#endif
