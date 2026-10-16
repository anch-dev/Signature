// ace_bridge.h - plain C interface over acestep.cpp for Swift.
//
// One engine owns one ModelStore in EVICT_STRICT mode: only one network
// (LM, text encoder, DiT or VAE) is resident at a time. With zero-copy
// weights the model files are mapped instead of copied, which is what lets
// small-memory iPhones run it.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ace_engine ace_engine;

typedef enum {
    ACE_STAGE_SONGWRITER = 0,  // 5Hz LM: lyrics (simple mode) + metadata + audio code plan
    ACE_STAGE_DIFFUSION  = 1,  // DiT denoising (text encoder runs at its start)
    ACE_STAGE_DECODE     = 2,  // VAE decode to audio
    ACE_STAGE_SAVING     = 3,  // writing the WAV
    ACE_STAGE_COUNT      = 4,
} ace_stage;

// fraction is 0..1 within the stage (estimated for the songwriter stage).
// Called on the generating thread. Return nonzero to cancel.
typedef int (*ace_progress_fn)(void * user, ace_stage stage, float fraction);

typedef struct {
    int zero_copy;   // map model files instead of copying weights (default 1)
    int low_memory;  // smaller KV cache and decode tiles for 4 GB devices (default 0)
    int use_cpu;     // 1 = run on the CPU cores (NEON) instead of the GPU (Metal). Slower, same RAM.
} ace_engine_options;

typedef struct {
    const char * lm_path;        // acestep-5Hz-lm-*.gguf  (NULL = skip songwriter)
    const char * text_enc_path;  // Qwen3-Embedding-*.gguf (required)
    const char * dit_path;       // acestep-v15-*.gguf (required)
    const char * vae_path;       // vae-*.gguf (required)
    const char * adapter_path;   // your trained .safetensors (NULL = none)
    float        adapter_scale;  // 1.0 = full strength
} ace_model_paths;

typedef struct {
    const char * caption;          // style prompt; in simple mode the song description
    const char * lyrics;           // "" + songwriter = it writes lyrics; "[Instrumental]" = no vocals
    const char * vocal_language;   // "en", "es", ... or NULL/"" for auto
    float        duration;         // seconds, 10..240
    int          bpm;              // 0 = let the songwriter decide
    int64_t      seed;             // -1 = random
    int          inference_steps;  // 0 = model default (turbo 8, sft/base 50)

    // Cover / remix / repaint (source audio: wav or mp3, any sample rate)
    const char * src_audio_path;   // NULL = make a new song (text2music)
    int          task;             // ACE_TASK_*
    float        cover_strength;   // cover: 0..1, how much of the original's structure to keep (default 1)
    float        cover_noise;      // cover: 0..1, 0 = fresh take, 1 = stay very close to the source (default 0)
    float        repaint_start;    // repaint: seconds
    float        repaint_end;      // repaint: seconds, -1 = to the end
} ace_song_request;

enum {
    ACE_TASK_NEW     = 0,  // text2music
    ACE_TASK_COVER   = 1,  // same song, new style / lyrics
    ACE_TASK_REPAINT = 2,  // regenerate one section, keep the rest
};

typedef struct {
    int64_t  seed_used;
    int      bpm;
    char     keyscale[32];
    float    duration;
    char     caption[1024];        // caption the DiT used (songwriter may rewrite it)
    char     lyrics[4096];         // lyrics used (written by the songwriter in simple mode)
    uint64_t peak_bytes[ACE_STAGE_COUNT];  // peak process memory per stage
    uint64_t mapped_ok;            // 1 if zero-copy mapping was used
} ace_song_info;

ace_engine * ace_engine_create(void);
void         ace_engine_free(ace_engine * e);
void         ace_engine_set_options(ace_engine * e, const ace_engine_options * o);

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

// Current process memory footprint in bytes (what iOS counts against the app).
uint64_t ace_memory_footprint(void);

#ifdef __cplusplus
}
#endif
