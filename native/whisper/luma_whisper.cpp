#include "whisper.h"
#include <atomic>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <string>
#include <new>
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
struct Engine {
  whisper_context* ctx = nullptr;
  std::atomic<bool> cancelled{false};
  int threads = 4;
  bool metal = false;
  std::string backend;
};
// whisper.cpp 1.8.1 exposes no context-backend getter. Observe its actual GPU
// selection and failure during initialization, rather than reporting what was
// merely compiled in. The global callback never retains a freed Engine pointer.
static thread_local Engine* creating_engine = nullptr;
static void quiet_log(enum ggml_log_level, const char* text, void*) {
  if (!creating_engine || !text) return;
  if (std::strstr(text, "whisper_backend_init_gpu: using Metal backend"))
    creating_engine->metal = true;
  if (std::strstr(text, "whisper_backend_init_gpu: failed to initialize Metal backend"))
    creating_engine->metal = false;
}
API int luma_abi_version() { return 2; }
API void* luma_create(const char* path, int threads) {
  whisper_log_set(quiet_log, nullptr);
  auto* engine = new(std::nothrow) Engine();
  if (!engine) return nullptr;
  auto params=whisper_context_default_params();
  #if defined(__APPLE__) && defined(LUMA_WHISPER_METAL)
  params.use_gpu=true;
  #else
  params.use_gpu=false;
  #endif
  creating_engine = engine;
  try {
    engine->ctx=whisper_init_from_file_with_params(path, params);
    engine->backend = engine->metal ? "Metal · whisper.cpp v1.8.1" : "CPU · whisper.cpp v1.8.1";
  } catch (...) {
    creating_engine = nullptr;
    if (engine->ctx) whisper_free(engine->ctx);
    delete engine;
    return nullptr;
  }
  creating_engine = nullptr;
  engine->threads=std::max(1,std::min(threads,16));
  if (!engine->ctx) { delete engine; return nullptr; }
  return engine;
}
// Clear cancellation before the Dart worker receives its command. Resetting it
// inside luma_run would lose a cancellation made while the command was queued.
API void luma_prepare(void* handle) {
  if (handle) static_cast<Engine*>(handle)->cancelled = false;
}
API int luma_run(void* handle, const float* samples, int count, const char* language, const char* prompt, int is_final) {
  auto* engine=static_cast<Engine*>(handle);
  if (!engine || !samples || count<=0 || count>16000*30) return -1;
  if (engine->cancelled) return 1;
  auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads=engine->threads;
  params.translate=false; params.no_context=true; params.single_segment=false;
  params.print_realtime=false; params.print_progress=false; params.print_timestamps=false; params.print_special=false;
  params.language=language && language[0] ? language : "auto";
  // Only explicit committed text may condition a new window. Never carry the
  // previous hypothesis implicitly when re-decoding the same growing audio.
  params.initial_prompt=prompt && prompt[0] ? prompt : nullptr;
  if (!is_final) params.temperature_inc=0.0f;
  params.suppress_blank=true; params.suppress_nst=true;
  params.abort_callback=[](void* p) { return static_cast<Engine*>(p)->cancelled.load(); };
  params.abort_callback_user_data=engine;
  return whisper_full(engine->ctx,params,samples,count);
}
API int luma_count(void* handle) { return whisper_full_n_segments(static_cast<Engine*>(handle)->ctx); }
API const char* luma_text(void* handle,int i) { return whisper_full_get_segment_text(static_cast<Engine*>(handle)->ctx,i); }
API int64_t luma_start(void* handle,int i) { return whisper_full_get_segment_t0(static_cast<Engine*>(handle)->ctx,i)*10000; }
API int64_t luma_end(void* handle,int i) { return whisper_full_get_segment_t1(static_cast<Engine*>(handle)->ctx,i)*10000; }
API void luma_cancel(void* handle) { if(handle) static_cast<Engine*>(handle)->cancelled=true; }
API void luma_destroy(void* handle) { auto* e=static_cast<Engine*>(handle); if(e){whisper_free(e->ctx);delete e;} }
API const char* luma_backend(void* handle) {
  return handle ? static_cast<Engine*>(handle)->backend.c_str() : "Whisper · 未加载";
}

// Independent CPU VAD contexts are owned by the VAD worker. The Whisper ABI
// above remains unchanged. Calls accept complete 32ms windows only: padding a
// partial live frame with zeros could manufacture an early speech endpoint.
struct VadEngine {
  whisper_vad_context* ctx = nullptr;
};
API int luma_vad_version() { return 1; }
API void* luma_vad_create(const char* path, int threads) {
  if (!path || !path[0]) return nullptr;
  whisper_log_set(quiet_log, nullptr);
  auto* engine = new(std::nothrow) VadEngine();
  if (!engine) return nullptr;
  auto params = whisper_vad_default_context_params();
  params.use_gpu = false;
  params.n_threads = std::max(1, std::min(threads, 4));
  try {
    engine->ctx = whisper_vad_init_from_file_with_params(path, params);
  } catch (...) {
    if (engine->ctx) whisper_vad_free(engine->ctx);
    delete engine;
    return nullptr;
  }
  if (!engine->ctx) { delete engine; return nullptr; }
  return engine;
}
API int luma_vad_run_probs(void* handle, const float* samples, int count,
                           float* output, int capacity) {
  auto* engine = static_cast<VadEngine*>(handle);
  if (!engine || !samples || !output || count <= 0 || count % 512 != 0 ||
      count > 16000 * 2 || capacity < count / 512) return -1;
  try {
    if (!whisper_vad_detect_speech(engine->ctx, samples, count)) return -2;
    const int n = whisper_vad_n_probs(engine->ctx);
    if (n != count / 512 || n > capacity) return -3;
    const float* probs = whisper_vad_probs(engine->ctx);
    for (int i = 0; i < n; ++i) {
      if (!std::isfinite(probs[i]) || probs[i] < 0 || probs[i] > 1) return -4;
      output[i] = probs[i];
    }
    return n;
  } catch (...) {
    return -5;
  }
}
API void luma_vad_free(void* handle) {
  auto* engine = static_cast<VadEngine*>(handle);
  if (engine) {
    whisper_vad_free(engine->ctx);
    delete engine;
  }
}
