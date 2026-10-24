// ============================================================
//  SpectruLenPor — native Moondream2 engine (llama.cpp + mmproj)
//  JNI bridge: called from MoondreamChannel.kt
// ============================================================
//  Build chain: CMake -> links llama.cpp (clone under cpp/llama.cpp)
//  Model: moondream2 Q4_K_M GGUF + mmproj file on device storage.
// ============================================================

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <mutex>
#include <cstring>

// ---- llama.cpp headers (from the cloned repo under cpp/llama.cpp) ----
#include "llama.h"
#include "clip.h"          // CLIP image encoder (mmproj)
#include "llava.h"         // llava_image_embed_make_with_bytes etc.

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "SpectruLenPor", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "SpectruLenPor", __VA_ARGS__)

namespace {

struct MoondreamContext {
    llama_model*   model = nullptr;
    llama_context* ctx   = nullptr;
    clip_ctx*      clip  = nullptr;
    std::mutex     mtx;   // one inference at a time (mobile RAM!)
};

MoondreamContext g_ctx;
std::string g_loadedModelPath;   // detect model changes from Dart
const int  N_THREADS      = 4;   // matches big cores on most phones
const int  CTX_N_CTX      = 2048;
const float CLIP_MIN_SCORE = 0.0f;

bool ensureLoaded(const std::string& modelPath) {
    if (g_ctx.model && g_loadedModelPath == modelPath) return true;

    // Model path changed -> reload fully.
    nativeUnloadImpl();

    llama_backend_init();

    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;   // CPU path: safest across devices
    g_ctx.model = llama_model_load_from_file(modelPath.c_str(), mparams);
    if (!g_ctx.model) { LOGE("llama model load failed"); return false; }

    auto cparams = llama_context_default_params();
    cparams.n_ctx   = CTX_N_CTX;
    cparams.n_threads = N_THREADS;
    g_ctx.ctx = llama_init_from_model(g_ctx.model, cparams);
    if (!g_ctx.ctx) { LOGE("llama context init failed"); return false; }

    // mmproj sits next to the gguf: <model_dir>/<model_stem>-mmproj-*.gguf
    std::string dir = modelPath.substr(0, modelPath.find_last_of('/') + 1);
    std::string mmproj;
    // Common names, checked in order:
    for (const char* cand : {
        "mmproj-model-f16.gguf", "moondream2-mmproj-f16.gguf",
        "mmproj.gguf"}) {
        std::string p = dir + cand;
        if (FILE* f = fopen(p.c_str(), "rb")) { fclose(f); mmproj = p; break; }
    }
    if (mmproj.empty()) { LOGE("mmproj file not found next to model"); return false; }

    g_ctx.clip = clip_model_load(mmproj.c_str(), /*verbosity=*/1);
    if (!g_ctx.clip) { LOGE("clip (mmproj) load failed"); return false; }

    g_loadedModelPath = modelPath;
    LOGI("Moondream loaded: %s", modelPath.c_str());
    return true;
}

// Decode JPEG bytes through stb_image (bundled by llama.cpp tools).
std::vector<unsigned char> decode_jpeg(const uint8_t* data, size_t size,
                                       int& w, int& h, int& c) {
    // llama.cpp's llava utils use stb_image internally; we hand the raw
    // buffer to llava_image_embed_make_with_bytes which decodes itself.
    return {}; // (placeholder — actual decode happens inside llama.cpp)
}

std::string runCaption(const std::string& modelPath,
                       const uint8_t* jpg, size_t jpgLen,
                       const std::string& prompt, int maxTokens) {
    if (!ensureLoaded(modelPath)) return "";

    std::lock_guard<std::mutex> lock(g_ctx.mtx);

    // 1) Image -> embeddings via CLIP (llava API).
    auto embeds = llava_image_embed_make_with_bytes(
        g_ctx.clip, N_THREADS, jpg, jpgLen, /*n_embd_per_token=*/4096);
    if (!embeds) { LOGE("image embed failed"); return ""; }

    // 2) Build prompt: <image> placeholders + user prompt.
    int n_img_tokens = embeds->n_image_pos;
    std::string full = prompt;
    std::string img_markers;
    for (int i = 0; i < n_img_tokens; ++i) img_markers += "<image>";
    full = img_markers + full;

    // 3) Tokenize text part.
    const llama_vocab* vocab = llama_model_get_vocab(g_ctx.model);
    int n_prompt = -llava_tokenize(
        g_ctx.ctx, vocab, full, /*add_bos=*/true, nullptr, 0, /*parse_special=*/true);
    std::vector<llama_token> tokens(n_prompt);
    llava_tokenize(g_ctx.ctx, vocab, full, true, tokens.data(), n_prompt, true);

    // 4) Prefill image embeddings, then decode text tokens.
    llava_eval_image_embed(g_ctx.ctx, embeds, N_THREADS, &n_prompt);

    for (auto t : tokens) {
        llama_token t2[1] = {t};
        if (llama_decode(g_ctx.ctx, llama_batch_get_one(t2, 1, n_prompt, 0))) {
            LOGE("decode failed");
            break;
        }
        n_prompt++;
    }

    // 5) Greedy generation loop.
    std::string out;
    for (int i = 0; i < maxTokens; ++i) {
        llama_token next = llama_sampler_sample(
            llama_sampler_init_greedy(), g_ctx.ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;

        char buf[64];
        int n = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (n > 0) out.append(buf, n);

        llama_token t[1] = {next};
        if (llama_decode(g_ctx.ctx, llama_batch_get_one(t, 1, n_prompt, 0))) break;
        n_prompt++;
    }

    llava_image_embed_free(embeds);
    LOGI("caption: %s", out.c_str());
    return out;
}

void nativeUnloadImpl() {
    if (g_ctx.ctx)   { llama_free(g_ctx.ctx);            g_ctx.ctx = nullptr; }
    if (g_ctx.model) { llama_model_free(g_ctx.model);    g_ctx.model = nullptr; }
    if (g_ctx.clip)  { clip_free(g_ctx.clip);            g_ctx.clip = nullptr; }
    g_loadedModelPath.clear();
    LOGI("Moondream unloaded");
}

} // namespace

// ------------------- JNI exports -------------------

extern "C" JNIEXPORT jstring JNICALL
Java_com_spectraglass_app_MoondreamChannel_nativeCaption(
    JNIEnv* env, jobject /*thiz*/, jstring jModelPath, jbyteArray jJpg,
    jstring jPrompt, jint jMaxTokens) {

    const char* modelPath = env->GetStringUTFChars(jModelPath, nullptr);
    const char* prompt = env->GetStringUTFChars(jPrompt, nullptr);

    auto jpgLen = static_cast<size_t>(env->GetArrayLength(jJpg));
    auto jpgData = std::vector<uint8_t>(jpgLen);
    env->GetByteArrayRegion(jJpg, 0, jpgLen,
                            reinterpret_cast<jbyte*>(jpgData.data()));

    std::string caption = runCaption(modelPath, jpgData.data(), jpgLen,
                                     prompt, jMaxTokens);

    env->ReleaseStringUTFChars(jModelPath, modelPath);
    env->ReleaseStringUTFChars(jPrompt, prompt);

    if (caption.empty()) return nullptr;
    return env->NewStringUTF(caption.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_spectraglass_app_MoondreamChannel_nativeUnload(JNIEnv*, jobject) {
    nativeUnloadImpl();
}
