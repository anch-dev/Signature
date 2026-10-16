// smoke.c - desktop check that the bridge links and runs end to end.
//   signature-smoke <models_dir> [adapter.safetensors]
#include "ace_bridge.h"

#include <stdio.h>
#include <string.h>

static int on_progress(void * user, ace_stage stage, float f) {
    (void) user;
    static const char * names[] = { "songwriter", "diffusion", "decode", "saving" };
    fprintf(stderr, "\r%-10s %5.1f%%", names[stage], f * 100.0f);
    if (f >= 1.0f) {
        fprintf(stderr, "\n");
    }
    return 0;
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <models_dir> [adapter]\n", argv[0]);
        return 2;
    }
    char lm[1024], te[1024], dit[1024], vae[1024];
    snprintf(lm, sizeof lm, "%s/acestep-5Hz-lm-0.6B-Q8_0.gguf", argv[1]);
    snprintf(te, sizeof te, "%s/Qwen3-Embedding-0.6B-Q8_0.gguf", argv[1]);
    snprintf(dit, sizeof dit, "%s/acestep-v15-turbo-Q4_K_M.gguf", argv[1]);
    snprintf(vae, sizeof vae, "%s/vae-BF16.gguf", argv[1]);

    ace_model_paths m = { lm, te, dit, vae, argc > 2 ? argv[2] : NULL, 1.0f };
    ace_song_request r = { "upbeat synth pop, female vocal, bright chorus",
                           "[Verse]\nCity lights are calling out my name\n[Chorus]\nWe run tonight", "en", 20.0f, 0,
                           42, 0 };

    ace_engine * e = ace_engine_create();
    if (!e) {
        fprintf(stderr, "engine create failed\n");
        return 1;
    }
    ace_song_info info;
    char          err[256] = { 0 };
    int           rc       = ace_engine_generate(e, &m, &r, "smoke.wav", on_progress, NULL, &info, err, sizeof err);
    if (rc == 0) {
        printf("ok: smoke.wav seed=%lld bpm=%d key=%s\n", (long long) info.seed_used, info.bpm, info.keyscale);
    } else {
        printf("rc=%d err=%s\n", rc, err);
    }
    ace_engine_free(e);
    return rc == 0 ? 0 : 1;
}
