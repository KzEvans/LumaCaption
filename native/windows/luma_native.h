#ifndef LUMACAPTION_NATIVE_WINDOWS_LUMA_NATIVE_H_
#define LUMACAPTION_NATIVE_WINDOWS_LUMA_NATIVE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>
#include <optional>

namespace luma {

// Own on the Flutter platform thread. Destroy before the engine/messenger.
class NativeBridge {
 public:
  NativeBridge(flutter::BinaryMessenger* messenger, HWND main_window);
  ~NativeBridge();
  NativeBridge(const NativeBridge&) = delete;
  NativeBridge& operator=(const NativeBridge&) = delete;
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);
  void Shutdown();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace luma
#endif
