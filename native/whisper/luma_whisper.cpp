#include "whisper.h"
#include <atomic>
#include <algorithm>
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
};
static void quiet_log(enum ggml_log_level, const char*, void*) {}
API int luma_abi_version() { return 2; }
API void* luma_create(const char* path, int threads) {
  whisper_log_set(quiet_log, nullptr);
  auto* engine = new(std::nothrow) Engine();
  if (!engine) return nullptr;
  auto params=whisper_context_default_params();
  params.use_gpu=false; // CPU is the only backend validated by this build.
  try {
    engine->ctx=whisper_init_from_file_with_params(path, params);
  } catch (...) {
    if (engine->ctx) whisper_free(engine->ctx);
    delete engine;
    return nullptr;
  }
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
  // luma_create explicitly disables GPU inference on the shared baseline.
  return handle ? "CPU · whisper.cpp v1.8.1" : "Whisper · 未加载";
}
