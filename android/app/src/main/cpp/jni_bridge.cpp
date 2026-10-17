// JNI bridge: Kotlin <-> ace_bridge (acestep.cpp). Same C API the iOS app uses.

#include "ace_bridge.h"

#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace {

// ---- stderr/stdout capture into a ring buffer (the in-app terminal) -------
std::mutex              g_log_mu;
std::deque<std::string> g_log;          // drained by Kotlin
bool                    g_log_started = false;

void * log_reader(void * arg) {
    int  fd = (int) (intptr_t) arg;
    char buf[4096];
    std::string line;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            break;
        }
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                __android_log_write(ANDROID_LOG_INFO, "SignatureEngine", line.c_str());
                std::lock_guard<std::mutex> lk(g_log_mu);
                g_log.push_back(line);
                while (g_log.size() > 4000) {
                    g_log.pop_front();
                }
                line.clear();
            } else if (buf[i] != '\r') {
                line.push_back(buf[i]);
            }
        }
    }
    return nullptr;
}

void start_log_capture() {
    if (g_log_started) {
        return;
    }
    g_log_started = true;
    int fds[2];
    if (pipe(fds) != 0) {
        return;
    }
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    pthread_t t;
    pthread_create(&t, nullptr, log_reader, (void *) (intptr_t) fds[0]);
    pthread_detach(t);
}

// ---- progress callback into Kotlin ----------------------------------------
struct Progress {
    JNIEnv *  env;
    jobject   listener;
    jmethodID method;   // boolean onProgress(int stage, float fraction)  -> true = cancel
};

int progress_cb(void * user, ace_stage stage, float fraction) {
    auto * p = (Progress *) user;
    if (!p || !p->listener) {
        return 0;
    }
    jboolean cancel = p->env->CallBooleanMethod(p->listener, p->method, (jint) stage, (jfloat) fraction);
    if (p->env->ExceptionCheck()) {
        p->env->ExceptionClear();
        return 0;
    }
    return cancel ? 1 : 0;
}

struct JStr {
    JNIEnv *    env;
    jstring     js;
    const char * c = nullptr;
    JStr(JNIEnv * e, jobjectArray arr, int i) : env(e) {
        js = (jstring) e->GetObjectArrayElement(arr, i);
        c  = js ? e->GetStringUTFChars(js, nullptr) : nullptr;
    }
    ~JStr() {
        if (js && c) {
            env->ReleaseStringUTFChars(js, c);
        }
        if (js) {
            env->DeleteLocalRef(js);
        }
    }
    const char * get() const { return (c && c[0]) ? c : nullptr; }
    const char * str() const { return c ? c : ""; }
};

// Returns raw UTF-8 bytes (NewStringUTF wants modified UTF-8 and aborts on emoji).
jbyteArray to_bytes(JNIEnv * env, const std::string & s) {
    jbyteArray a = env->NewByteArray((jsize) s.size());
    env->SetByteArrayRegion(a, 0, (jsize) s.size(), (const jbyte *) s.data());
    return a;
}

std::string json_escape(const char * s) {
    std::string o;
    for (const char * p = s; *p; p++) {
        unsigned char ch = (unsigned char) *p;
        switch (ch) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (ch < 0x20) {
                    char b[8];
                    snprintf(b, sizeof(b), "\\u%04x", ch);
                    o += b;
                } else {
                    o += (char) ch;
                }
        }
    }
    return o;
}

}  // namespace

extern "C" {

JNIEXPORT void JNICALL Java_com_anchdev_signature_engine_Native_startLogCapture(JNIEnv *, jclass) {
    start_log_capture();
}

JNIEXPORT jbyteArray JNICALL Java_com_anchdev_signature_engine_Native_drainLog(JNIEnv * env, jclass) {
    std::string out;
    {
        std::lock_guard<std::mutex> lk(g_log_mu);
        for (auto & l : g_log) {
            out += l;
            out += '\n';
        }
        g_log.clear();
    }
    return to_bytes(env, out);
}

JNIEXPORT jlong JNICALL Java_com_anchdev_signature_engine_Native_create(JNIEnv *, jclass) {
    return (jlong) (intptr_t) ace_engine_create();
}

JNIEXPORT void JNICALL Java_com_anchdev_signature_engine_Native_free(JNIEnv *, jclass, jlong h) {
    ace_engine_free((ace_engine *) (intptr_t) h);
}

JNIEXPORT void JNICALL Java_com_anchdev_signature_engine_Native_setOptions(JNIEnv *, jclass, jlong h, jint zeroCopy,
                                                                           jint lowMemory, jint useCpu, jint verbose,
                                                                           jint streamLayers) {
    ace_engine_options o{};
    o.zero_copy     = zeroCopy;
    o.low_memory    = lowMemory;
    o.use_cpu       = useCpu;
    o.verbose       = verbose;
    o.stream_layers = streamLayers;
    ace_engine_set_options((ace_engine *) (intptr_t) h, &o);
}

JNIEXPORT jlong JNICALL Java_com_anchdev_signature_engine_Native_footprint(JNIEnv *, jclass) {
    return (jlong) ace_memory_footprint();
}

// [budget, headroom, footprint, physical, gpuTotal, unified]
JNIEXPORT jlongArray JNICALL Java_com_anchdev_signature_engine_Native_budget(JNIEnv * env, jclass, jint useCpu) {
    ace_memory_budget_info b = ace_memory_budget(useCpu);
    jlong v[6] = { (jlong) b.budget,   (jlong) b.headroom,  (jlong) b.footprint,
                   (jlong) b.physical, (jlong) b.gpu_total, (jlong) b.unified };
    jlongArray arr = env->NewLongArray(6);
    env->SetLongArrayRegion(arr, 0, 6, v);
    return arr;
}

// strings: caption, lyrics, language, srcAudio, lm, textEnc, dit, vae, adapter, outWav
// floats:  duration, adapterScale, coverStrength, coverNoise, repaintStart, repaintEnd, weirdness, styleInfluence, clarity
// ints:    bpm, steps, enhance, task, sampler
// Returns UTF-8 JSON with the song info, empty when cancelled; throws on error.
JNIEXPORT jbyteArray JNICALL Java_com_anchdev_signature_engine_Native_generate(JNIEnv * env, jclass, jlong h,
                                                                            jobjectArray strings, jfloatArray floats,
                                                                            jintArray ints, jlong seed,
                                                                            jobject listener) {
    JStr caption(env, strings, 0), lyrics(env, strings, 1), language(env, strings, 2), src(env, strings, 3),
        lm(env, strings, 4), text(env, strings, 5), dit(env, strings, 6), vae(env, strings, 7), adapter(env, strings, 8),
        out(env, strings, 9);
    jfloat f[9];
    env->GetFloatArrayRegion(floats, 0, 9, f);
    jint i[5];
    env->GetIntArrayRegion(ints, 0, 5, i);

    ace_model_paths paths{};
    paths.lm_path       = lm.get();
    paths.text_enc_path = text.get();
    paths.dit_path      = dit.get();
    paths.vae_path      = vae.get();
    paths.adapter_path  = adapter.get();
    paths.adapter_scale = f[1];

    ace_song_request r{};
    r.caption         = caption.str();
    r.lyrics          = lyrics.str();
    r.vocal_language  = language.get();
    r.duration        = f[0];
    r.bpm             = i[0];
    r.seed            = seed;
    r.inference_steps = i[1];
    r.enhance_prompt  = i[2];
    r.src_audio_path  = src.get();
    r.task            = i[3];
    r.cover_strength  = f[2];
    r.cover_noise     = f[3];
    r.repaint_start   = f[4];
    r.repaint_end     = f[5];
    r.weirdness       = f[6];
    r.style_influence = f[7];
    r.clarity         = f[8];
    r.sampler         = i[4];

    Progress p{ env, listener, nullptr };
    if (listener) {
        jclass cls = env->GetObjectClass(listener);
        p.method   = env->GetMethodID(cls, "onProgress", "(IF)Z");
        env->DeleteLocalRef(cls);
    }

    auto * info = new ace_song_info();
    char   err[512] = { 0 };
    int    rc = ace_engine_generate((ace_engine *) (intptr_t) h, &paths, &r, out.str(), listener ? progress_cb : nullptr,
                                    listener ? &p : nullptr, info, err, (int) sizeof(err));
    std::string json;
    if (rc == 0) {
        char head[512];
        snprintf(head, sizeof(head),
                 "{\"seed\":%lld,\"bpm\":%d,\"key\":\"%s\",\"duration\":%.3f,\"streamed\":%d,\"peaks\":[%llu,%llu,%llu,%llu],",
                 (long long) info->seed_used, info->bpm, json_escape(info->keyscale).c_str(), info->duration,
                 (int) info->streamed, (unsigned long long) info->peak_bytes[0], (unsigned long long) info->peak_bytes[1],
                 (unsigned long long) info->peak_bytes[2], (unsigned long long) info->peak_bytes[3]);
        json = head;
        json += "\"caption\":\"" + json_escape(info->caption) + "\",\"lyrics\":\"" + json_escape(info->lyrics) + "\"}";
    }
    delete info;
    if (rc < 0) {
        jclass ex = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(ex, err[0] ? err : "generation failed");
        return nullptr;
    }
    return to_bytes(env, rc == 1 ? std::string() : json);
}

}  // extern "C"
