#include "luma_native.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <audioclient.h>
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>
#include <gdiplus.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincred.h>
#include <windowsx.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace luma {
namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
constexpr UINT kAudioMessage = WM_APP + 0x78;
constexpr UINT kTrayMessage = WM_APP + 0x79;
constexpr UINT kTrayId = 71;
constexpr int kToggleHotkey = 71;
constexpr int kRecoverHotkey = 72;
constexpr size_t kMaxQueuedEvents = 48;
constexpr size_t kMaxPacketBytes = 2 * 1024 * 1024;
constexpr wchar_t kOverlayClass[] = L"LumaCaptionOverlayWindow";
constexpr wchar_t kRegistryKey[] = L"Software\\LumaCaption";

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      text.data(), static_cast<int>(text.size()),
                                      nullptr, 0);
  if (!count) throw std::runtime_error("Invalid UTF-8");
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), result.data(), count);
  return result;
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                       static_cast<int>(text.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), count, nullptr, nullptr);
  return result;
}

struct NativeError : std::runtime_error {
  std::string code;
  NativeError(std::string error_code, const std::string& message)
      : std::runtime_error(message), code(std::move(error_code)) {}
};

void Check(HRESULT hr, const char* operation) {
  if (SUCCEEDED(hr)) return;
  char value[32]{};
  sprintf_s(value, " (HRESULT 0x%08lX)", static_cast<unsigned long>(hr));
  std::string code = "native_error";
  if (hr == E_ACCESSDENIED) code = "permission_denied";
  if (hr == AUDCLNT_E_DEVICE_INVALIDATED ||
      hr == AUDCLNT_E_RESOURCES_INVALIDATED) code = "device_changed";
  throw NativeError(code, std::string(operation) + value);
}

const EncodableValue* Field(const EncodableMap& map, const char* name) {
  const auto found = map.find(EncodableValue(name));
  return found == map.end() ? nullptr : &found->second;
}

std::string String(const EncodableMap& map, const char* name,
                   std::string fallback = {}) {
  const auto* value = Field(map, name);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : fallback;
}

double Number(const EncodableMap& map, const char* name, double fallback) {
  const auto* value = Field(map, name);
  if (value) {
    if (const auto* number = std::get_if<double>(value)) return *number;
    if (const auto* number = std::get_if<int32_t>(value)) return *number;
    if (const auto* number = std::get_if<int64_t>(value))
      return static_cast<double>(*number);
  }
  return fallback;
}

bool Boolean(const EncodableMap& map, const char* name, bool fallback) {
  const auto* value = Field(map, name);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag ? *flag : fallback;
}

EncodableMap ErrorEvent(const std::string& code, const std::string& message) {
  return {{EncodableValue("type"), EncodableValue("error")},
          {EncodableValue("code"), EncodableValue(code)},
          {EncodableValue("message"), EncodableValue(message)}};
}

bool IsAudio(const EncodableValue& event) {
  const auto* map = std::get_if<EncodableMap>(&event);
  return map && String(*map, "type") == "audio";
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR raw = nullptr;
  Check(SHGetKnownFolderPath(id, KF_FLAG_CREATE, nullptr, &raw),
        "Cannot locate user folder");
  std::wstring result(raw);
  CoTaskMemFree(raw);
  return result;
}

class DeviceNotifications final : public IMMNotificationClient {
 public:
  explicit DeviceNotifications(std::function<void(EDataFlow, const wchar_t*, bool)> callback)
      : callback_(std::move(callback)) {}
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --references_;
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (id == __uuidof(IUnknown) || id == __uuidof(IMMNotificationClient)) {
      *object = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id, DWORD state) override {
    callback_(eAll, id, state != DEVICE_STATE_ACTIVE);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR id) override {
    callback_(eAll, id, false);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override {
    callback_(eAll, id, true);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                    LPCWSTR id) override {
    if (role == eConsole) callback_(flow, id, true);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR id, const PROPERTYKEY) override {
    callback_(eAll, id, false);
    return S_OK;
  }
 private:
  std::atomic<ULONG> references_{1};
  std::function<void(EDataFlow, const wchar_t*, bool)> callback_;
};

}  // namespace

class NativeBridge::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, HWND main_window)
      : main_(main_window) {
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stop_event_) throw std::runtime_error("Cannot create capture stop event");
    Gdiplus::GdiplusStartupInput startup;
    if (Gdiplus::GdiplusStartup(&gdiplus_token_, &startup, nullptr) != Gdiplus::Ok)
      throw std::runtime_error("Cannot initialize subtitle renderer");
    methods_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "lumacaption/native", &flutter::StandardMethodCodec::GetInstance());
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "lumacaption/audio", &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
        [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          sink_ = std::move(sink);
          return nullptr;
        },
        [this](const EncodableValue*)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          Stop();
          sink_.reset();
          return nullptr;
        }));
    methods_->SetMethodCallHandler([this](const auto& call, auto result) {
      try { HandleCall(call, std::move(result)); }
      catch (const std::exception&) {
        // HandleCall owns result and catches every operation's exception.
      }
    });
    CreateTray();
    RegisterHotKey(main_, kToggleHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'L');
    RegisterHotKey(main_, kRecoverHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'I');
  }

  ~Impl() { Shutdown(); }

  void Shutdown() {
    if (shutdown_) return;
    shutdown_ = true;
    Stop();
    methods_->SetMethodCallHandler(nullptr);
    events_->SetStreamHandler(nullptr);
    sink_.reset();
    UnregisterHotKey(main_, kToggleHotkey);
    UnregisterHotKey(main_, kRecoverHotkey);
    NOTIFYICONDATAW tray{};
    tray.cbSize = sizeof(tray);
    tray.hWnd = main_;
    tray.uID = kTrayId;
    Shell_NotifyIconW(NIM_DELETE, &tray);
    if (overlay_) {
      SavePlacement();
      DestroyWindow(overlay_);
      overlay_ = nullptr;
    }
    if (gdiplus_token_) Gdiplus::GdiplusShutdown(gdiplus_token_);
    if (stop_event_) CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }

  std::optional<LRESULT> Message(UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == kAudioMessage) { DrainEvents(); return 0; }
    if (message == kTrayMessage) {
      if (LOWORD(lparam) == WM_RBUTTONUP || LOWORD(lparam) == WM_CONTEXTMENU)
        TrayMenu();
      if (LOWORD(lparam) == WM_LBUTTONDBLCLK || LOWORD(lparam) == NIN_SELECT)
        ShowMain();
      return 0;
    }
    if (message == taskbar_created_) { CreateTray(); return 0; }
    if (message == WM_HOTKEY) {
      if (wparam == kToggleHotkey) ToggleOverlay();
      if (wparam == kRecoverHotkey) { SetClickThrough(false); ShowOverlay(); }
      return 0;
    }
    if (message == WM_CLOSE && !quitting_) {
      ShowWindow(main_, SW_HIDE);
      return 0;
    }
    if (message == WM_DISPLAYCHANGE) ClampOverlay();
    if (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) {
      Stop();
      Push(EncodableValue(ErrorEvent("suspended", "System sleep stopped capture; start a new session after wake.")));
    }
    if (message == WM_QUERYENDSESSION) { Stop(); return TRUE; }
    return std::nullopt;
  }

 private:
  void Push(EncodableValue event) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      if (queue_.size() >= kMaxQueuedEvents) {
        const auto audio = std::find_if(queue_.begin(), queue_.end(), IsAudio);
        if (audio != queue_.end()) queue_.erase(audio);
        else queue_.pop_front();
        ++dropped_;
      }
      queue_.push_back(std::move(event));
      if (dispatch_pending_) return;
      dispatch_pending_ = true;
    }
    PostMessageW(main_, kAudioMessage, 0, 0);
  }

  void DrainEvents() {
    std::deque<EncodableValue> ready;
    uint64_t dropped = 0;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      ready.swap(queue_);
      dropped = std::exchange(dropped_, 0);
      dispatch_pending_ = false;
    }
    if (!sink_) return;
    if (dropped) {
      auto error = ErrorEvent("audio_overflow", "Audio queue was full; stale packets were dropped.");
      error[EncodableValue("dropped")] = EncodableValue(static_cast<int64_t>(dropped));
      sink_->Success(EncodableValue(error));
    }
    for (const auto& event : ready) sink_->Success(event);
  }

  void ClearAudioQueue() {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.erase(std::remove_if(queue_.begin(), queue_.end(), IsAudio), queue_.end());
  }

  void Stop() {
    if (stop_event_) SetEvent(stop_event_);
    if (capture_thread_.joinable()) capture_thread_.join();
    capturing_ = false;
    paused_ = false;
    ClearAudioQueue();
  }

  void Start(const std::string& source, const std::string& device_id) {
    if (source != "system" && source != "microphone")
      throw NativeError("invalid_source", "Choose system or microphone audio.");
    if (!sink_) throw NativeError("not_listening", "Subscribe to audio events before starting capture.");
    Stop();
    ResetEvent(stop_event_);
    auto ready = std::make_shared<std::promise<std::string>>();
    auto future = ready->get_future();
    capture_thread_ = std::thread([this, source, device_id, ready] {
      Capture(source, device_id, ready);
    });
    if (future.wait_for(std::chrono::seconds(8)) != std::future_status::ready) {
      Stop();
      throw NativeError("capture_timeout", "The audio endpoint did not initialize in time.");
    }
    const auto error = future.get();
    if (!error.empty()) { Stop(); throw NativeError("capture_failed", error); }
  }

  void Capture(const std::string& source, const std::string& device_id,
               const std::shared_ptr<std::promise<std::string>>& ready) {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool announced = false;
    HANDLE samples_event = nullptr;
    HANDLE mmcss = nullptr;
    WAVEFORMATEX* mix = nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    ComPtr<DeviceNotifications> notifications;
    std::atomic<bool> endpoint_changed{false};
    try {
      Check(com_result, "Cannot initialize audio COM apartment");
      Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                             IID_PPV_ARGS(&enumerator)), "Cannot enumerate audio devices");
      const EDataFlow flow = source == "system" ? eRender : eCapture;
      if (device_id.empty())
        Check(enumerator->GetDefaultAudioEndpoint(flow, eConsole, &device), "No default audio device");
      else
        Check(enumerator->GetDevice(Wide(device_id).c_str(), &device), "Selected audio device is unavailable");
      LPWSTR raw_id = nullptr;
      Check(device->GetId(&raw_id), "Cannot read audio device identity");
      const std::wstring endpoint_id(raw_id);
      CoTaskMemFree(raw_id);
      ComPtr<IMMEndpoint> endpoint;
      Check(device.As(&endpoint), "Cannot inspect audio endpoint");
      EDataFlow actual_flow = eAll;
      Check(endpoint->GetDataFlow(&actual_flow), "Cannot inspect audio direction");
      if (actual_flow != flow) throw NativeError("invalid_device", "Audio device does not match selected source.");
      notifications.Attach(new DeviceNotifications(
          [this, flow, device_id, endpoint_id, &endpoint_changed](EDataFlow changed_flow, const wchar_t* id, bool invalid) {
            const std::wstring changed_id(id ? id : L"");
            Push(EncodableValue(EncodableMap{{EncodableValue("type"), EncodableValue("devicesChanged")}}));
            const bool default_changed = device_id.empty() && changed_flow == flow && changed_id != endpoint_id;
            const bool removed = changed_flow == eAll && invalid && changed_id == endpoint_id;
            if (default_changed || removed) { endpoint_changed = true; SetEvent(stop_event_); }
          }));
      Check(enumerator->RegisterEndpointNotificationCallback(notifications.Get()), "Cannot watch audio devices");
      Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(client.GetAddressOf())), "Cannot open audio endpoint");
      Check(client->GetMixFormat(&mix), "Cannot read audio format");
      if (!mix->nChannels || !mix->nSamplesPerSec || mix->nChannels > 32)
        throw NativeError("unsupported_format", "Unsupported channel count or sample rate.");
      WORD format_tag = mix->wFormatTag;
      WORD valid_bits = mix->wBitsPerSample;
      if (format_tag == WAVE_FORMAT_EXTENSIBLE && mix->cbSize >= 22) {
        const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(mix);
        valid_bits = extended->Samples.wValidBitsPerSample;
        if (IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) format_tag = WAVE_FORMAT_IEEE_FLOAT;
        else if (IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) format_tag = WAVE_FORMAT_PCM;
      }
      const bool float32 = format_tag == WAVE_FORMAT_IEEE_FLOAT && mix->wBitsPerSample == 32;
      const bool pcm = format_tag == WAVE_FORMAT_PCM &&
          (mix->wBitsPerSample == 8 || mix->wBitsPerSample == 16 ||
           mix->wBitsPerSample == 24 || mix->wBitsPerSample == 32);
      if (!float32 && !pcm) throw NativeError("unsupported_format", "Audio endpoint format is not PCM or float32.");
      if (valid_bits == 0 || valid_bits > mix->wBitsPerSample ||
          mix->nBlockAlign < mix->nChannels * (mix->wBitsPerSample / 8))
        throw NativeError("unsupported_format", "Malformed PCM channel layout.");
      samples_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
      if (!samples_event) throw NativeError("native_error", "Cannot create audio event.");
      DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST;
      if (flow == eRender) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
      Check(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 1000000, 0, mix, nullptr), "Cannot initialize shared audio capture");
      Check(client->SetEventHandle(samples_event), "Cannot register audio event");
      Check(client->GetService(IID_PPV_ARGS(&capture)), "Cannot open audio capture service");
      DWORD task_index = 0;
      mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);
      Check(client->Start(), "Cannot start audio capture");
      capturing_ = true;
      ready->set_value("");
      announced = true;
      int64_t sequence = 0;
      HANDLE waits[] = {stop_event_, samples_event};
      while (WaitForMultipleObjects(2, waits, FALSE, 1000) != WAIT_OBJECT_0) {
        UINT32 packet_frames = 0;
        Check(capture->GetNextPacketSize(&packet_frames), "Cannot read audio packet size");
        while (packet_frames) {
          BYTE* bytes = nullptr;
          UINT32 frames = 0;
          DWORD packet_flags = 0;
          UINT64 position = 0, timestamp_100ns = 0;
          Check(capture->GetBuffer(&bytes, &frames, &packet_flags, &position, &timestamp_100ns), "Cannot read audio packet");
          // Always release the WASAPI buffer before publishing to Flutter.
          try {
            const size_t samples = static_cast<size_t>(frames) * mix->nChannels;
            if (samples * sizeof(float) > kMaxPacketBytes)
              throw NativeError("audio_overflow", "Audio device returned an oversized packet.");
            if (!paused_ && !(packet_flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)) {
              std::vector<uint8_t> pcm_bytes(samples * sizeof(float));
              for (size_t i = 0; i < samples; ++i) {
                float sample = 0;
                if (!(packet_flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
                  const size_t frame = i / mix->nChannels;
                  const size_t channel = i % mix->nChannels;
                  const BYTE* value = bytes + frame * mix->nBlockAlign + channel * (mix->wBitsPerSample / 8);
                  if (float32) std::memcpy(&sample, value, sizeof(sample));
                  else if (mix->wBitsPerSample == 8) sample = (static_cast<int>(value[0]) - 128) / 128.0f;
                  else {
                    int32_t signed_value = 0;
                    if (mix->wBitsPerSample == 16) {
                      int16_t value16 = 0;
                      std::memcpy(&value16, value, sizeof(value16));
                      signed_value = value16;
                    } else if (mix->wBitsPerSample == 24) {
                      signed_value = static_cast<int32_t>(value[0]) |
                          (static_cast<int32_t>(value[1]) << 8) | (static_cast<int32_t>(value[2]) << 16);
                      if (signed_value & 0x00800000) signed_value |= static_cast<int32_t>(0xff000000u);
                    } else std::memcpy(&signed_value, value, sizeof(signed_value));
                    // Extensible PCM is left aligned; full container scaling is correct.
                    sample = static_cast<float>(static_cast<double>(signed_value) /
                        std::ldexp(1.0, mix->wBitsPerSample - 1));
                  }
                }
                if (!std::isfinite(sample)) sample = 0;
                sample = std::clamp(sample, -1.0f, 1.0f);
                std::memcpy(pcm_bytes.data() + i * sizeof(float), &sample, sizeof(float));
              }
              Check(capture->ReleaseBuffer(frames), "Cannot release audio packet");
              frames = 0;
              if (packet_flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)
                Push(EncodableValue(ErrorEvent("audio_discontinuity", "The audio endpoint reported a gap in capture.")));
              Push(EncodableValue(EncodableMap{
                  {EncodableValue("type"), EncodableValue("audio")},
                  {EncodableValue("pcm"), EncodableValue(std::move(pcm_bytes))},
                  {EncodableValue("sampleRate"), EncodableValue(static_cast<int32_t>(mix->nSamplesPerSec))},
                  {EncodableValue("channels"), EncodableValue(static_cast<int32_t>(mix->nChannels))},
                  {EncodableValue("timestampUs"), EncodableValue(static_cast<int64_t>(timestamp_100ns / 10))},
                  {EncodableValue("sequence"), EncodableValue(sequence++)}}));
            } else {
              Check(capture->ReleaseBuffer(frames), "Cannot release skipped audio packet");
              frames = 0;
              if (packet_flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)
                Push(EncodableValue(ErrorEvent("timestamp_error", "An audio packet with an invalid timestamp was discarded.")));
            }
          } catch (...) { if (frames) capture->ReleaseBuffer(frames); throw; }
          Check(capture->GetNextPacketSize(&packet_frames), "Cannot advance audio capture");
          if (WaitForSingleObject(stop_event_, 0) == WAIT_OBJECT_0) break;
        }
      }
      if (endpoint_changed)
        Push(EncodableValue(ErrorEvent("device_changed", "Audio endpoint changed; choose a device and start a new session.")));
    } catch (const NativeError& error) {
      if (!announced) ready->set_value(error.what());
      Push(EncodableValue(ErrorEvent(error.code, error.what())));
    } catch (const std::exception& error) {
      if (!announced) ready->set_value(error.what());
      Push(EncodableValue(ErrorEvent("capture_failed", error.what())));
    }
    capturing_ = false;
    if (client) client->Stop();
    if (enumerator && notifications)
      enumerator->UnregisterEndpointNotificationCallback(notifications.Get());
    notifications.Reset();
    capture.Reset();
    client.Reset();
    device.Reset();
    enumerator.Reset();
    if (mix) CoTaskMemFree(mix);
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    if (samples_event) CloseHandle(samples_event);
    if (SUCCEEDED(com_result)) CoUninitialize();
  }

  EncodableList Devices() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                           IID_PPV_ARGS(&enumerator)), "Cannot enumerate audio devices");
    EncodableList output;
    for (const auto flow : {eRender, eCapture}) {
      std::wstring default_id;
      ComPtr<IMMDevice> default_device;
      if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(flow, eConsole, &default_device))) {
        LPWSTR id = nullptr;
        if (SUCCEEDED(default_device->GetId(&id))) { default_id = id; CoTaskMemFree(id); }
      }
      ComPtr<IMMDeviceCollection> devices;
      Check(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &devices), "Cannot list audio endpoints");
      UINT count = 0;
      Check(devices->GetCount(&count), "Cannot count audio endpoints");
      for (UINT i = 0; i < count; ++i) {
        ComPtr<IMMDevice> device;
        Check(devices->Item(i, &device), "Cannot inspect audio endpoint");
        LPWSTR id = nullptr;
        Check(device->GetId(&id), "Cannot identify audio endpoint");
        const std::wstring device_id(id);
        CoTaskMemFree(id);
        ComPtr<IPropertyStore> properties;
        Check(device->OpenPropertyStore(STGM_READ, &properties), "Cannot read audio device properties");
        PROPVARIANT name;
        PropVariantInit(&name);
        const HRESULT named = properties->GetValue(PKEY_Device_FriendlyName, &name);
        const std::wstring device_name = SUCCEEDED(named) && name.vt == VT_LPWSTR
            ? name.pwszVal : L"Audio endpoint";
        PropVariantClear(&name);
        output.emplace_back(EncodableMap{
            {EncodableValue("id"), EncodableValue(Utf8(device_id))},
            {EncodableValue("name"), EncodableValue(Utf8(device_name))},
            {EncodableValue("source"), EncodableValue(flow == eRender ? "system" : "microphone")},
            {EncodableValue("isDefault"), EncodableValue(device_id == default_id)}});
      }
    }
    return output;
  }

  void CreateOverlay() {
    if (overlay_) return;
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = OverlayProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kOverlayClass;
    RegisterClassExW(&window_class);
    RECT work{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    RECT bounds{work.left + 120, work.bottom - 260, work.left + 920, work.bottom - 80};
    HKEY settings = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, KEY_READ, &settings) == ERROR_SUCCESS) {
      DWORD size = sizeof(bounds), type = 0;
      RECT saved{};
      if (RegQueryValueExW(settings, L"OverlayBounds", nullptr, &type,
                           reinterpret_cast<BYTE*>(&saved), &size) == ERROR_SUCCESS &&
          type == REG_BINARY && size == sizeof(saved) && saved.right - saved.left >= 240 &&
          saved.bottom - saved.top >= 80 && saved.right - saved.left <= 12000 && saved.bottom - saved.top <= 6000)
        bounds = saved;
      RegCloseKey(settings);
    }
    overlay_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
        kOverlayClass, L"LumaCaption 字幕", WS_POPUP | WS_THICKFRAME,
        bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top,
        nullptr, nullptr, GetModuleHandleW(nullptr), this);
    if (!overlay_) throw NativeError("overlay_failed", "Cannot create subtitle window.");
    ClampOverlay();
    SetClickThrough(click_through_);
  }

  static LRESULT CALLBACK OverlayProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    Impl* self = reinterpret_cast<Impl*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      self = static_cast<Impl*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
      self->overlay_ = window;
    }
    if (!self) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
      case WM_NCCALCSIZE: return 0;
      case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
      case WM_ERASEBKGND: return 1;
      case WM_NCHITTEST: {
        if (self->click_through_) return HTTRANSPARENT;
        RECT bounds{};
        GetWindowRect(window, &bounds);
        const int x = GET_X_LPARAM(lparam), y = GET_Y_LPARAM(lparam);
        const int edge = MulDiv(9, static_cast<int>(GetDpiForWindow(window)), 96);
        const bool left = x < bounds.left + edge, right = x >= bounds.right - edge;
        const bool top = y < bounds.top + edge, bottom = y >= bounds.bottom - edge;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
        return HTCAPTION;
      }
      case WM_GETMINMAXINFO: {
        auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
        limits->ptMinTrackSize.x = 240;
        limits->ptMinTrackSize.y = 80;
        limits->ptMaxTrackSize.x = 12000;
        limits->ptMaxTrackSize.y = 6000;
        return 0;
      }
      case WM_DPICHANGED: {
        const auto* bounds = reinterpret_cast<RECT*>(lparam);
        SetWindowPos(window, HWND_TOPMOST, bounds->left, bounds->top,
                     bounds->right - bounds->left, bounds->bottom - bounds->top, SWP_NOACTIVATE);
        self->RenderOverlay();
        return 0;
      }
      case WM_SIZE: self->RenderOverlay(); return 0;
      case WM_EXITSIZEMOVE: self->SavePlacement(); return 0;
      case WM_DISPLAYCHANGE: self->ClampOverlay(); return 0;
      case WM_CONTEXTMENU: self->TrayMenu(); return 0;
      case WM_CLOSE: ShowWindow(window, SW_HIDE); return 0;
      case WM_PAINT: {
        PAINTSTRUCT paint{};
        BeginPaint(window, &paint);
        EndPaint(window, &paint);
        return 0;
      }
      default: return DefWindowProcW(window, message, wparam, lparam);
    }
  }

  void RenderOverlay() {
    if (!overlay_ || !gdiplus_token_) return;
    RECT bounds{};
    GetWindowRect(overlay_, &bounds);
    const int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0 || width > 12000 || height > 6000) return;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = width;
    bitmap_info.bmiHeader.biHeight = -height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &bitmap_info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !memory) {
      if (bitmap) DeleteObject(bitmap);
      if (memory) DeleteDC(memory);
      ReleaseDC(nullptr, screen);
      return;
    }
    const auto old = SelectObject(memory, bitmap);
    {
      Gdiplus::Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(pixels));
      Gdiplus::Graphics graphics(&surface);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
      graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
      const float scale = static_cast<float>(GetDpiForWindow(overlay_)) / 96.0f;
      const float radius = std::min(24.0f * scale, static_cast<float>(height));
      Gdiplus::GraphicsPath rounded;
      const float w = static_cast<float>(width), h = static_cast<float>(height);
      rounded.AddArc(0.0f, 0.0f, radius, radius, 180.0f, 90.0f);
      rounded.AddArc(w - radius, 0.0f, radius, radius, 270.0f, 90.0f);
      rounded.AddArc(w - radius, h - radius, radius, radius, 0.0f, 90.0f);
      rounded.AddArc(0.0f, h - radius, radius, radius, 90.0f, 90.0f);
      rounded.CloseFigure();
      Gdiplus::SolidBrush background(Gdiplus::Color(static_cast<BYTE>(std::lround(opacity_ * 255)), 20, 23, 30));
      graphics.FillPath(&background, &rounded);
      Gdiplus::FontFamily family(L"Segoe UI");
      Gdiplus::Font font(&family, static_cast<float>(font_size_) * scale,
                         Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::Font secondary(&family, static_cast<float>(font_size_) * 0.8f * scale,
                              Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::StringFormat format;
      format.SetAlignment(Gdiplus::StringAlignmentCenter);
      format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
      Gdiplus::SolidBrush foreground(Gdiplus::Color(255, 250, 250, 252));
      Gdiplus::SolidBrush muted(Gdiplus::Color(255, 200, 204, 217));
      const float padding = 16.0f * scale;
      if (display_ == "bilingual" && !original_.empty() && !translation_.empty()) {
        Gdiplus::RectF top(padding, padding, w - padding * 2, (h - padding * 2) * 0.43f);
        Gdiplus::RectF bottom(padding, top.GetBottom(), top.Width, (h - padding * 2) * 0.57f);
        graphics.DrawString(original_.c_str(), static_cast<INT>(original_.size()), &secondary, top, &format, &muted);
        graphics.DrawString(translation_.c_str(), static_cast<INT>(translation_.size()), &font, bottom, &format, &foreground);
      } else {
        const std::wstring& text = display_ == "original" ? original_ :
            display_ == "translation" ? translation_ : translation_.empty() ? original_ : translation_;
        Gdiplus::RectF area(padding, padding, w - padding * 2, h - padding * 2);
        graphics.DrawString(text.c_str(), static_cast<INT>(text.size()), &font, area, &format, &foreground);
      }
      graphics.Flush(Gdiplus::FlushIntentionSync);
    }
    POINT destination{bounds.left, bounds.top}, origin{};
    SIZE size{width, height};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(overlay_, screen, &destination, &size, memory, &origin, 0, &blend, ULW_ALPHA);
    SelectObject(memory, old);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
  }

  void ClampOverlay() {
    if (!overlay_) return;
    RECT bounds{};
    GetWindowRect(overlay_, &bounds);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoW(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor)) return;
    const auto& work = monitor.rcWork;
    const int width = std::min(bounds.right - bounds.left, work.right - work.left);
    const int height = std::min(bounds.bottom - bounds.top, work.bottom - work.top);
    const int left = std::clamp(static_cast<int>(bounds.left), static_cast<int>(work.left), static_cast<int>(work.right) - width);
    const int top = std::clamp(static_cast<int>(bounds.top), static_cast<int>(work.top), static_cast<int>(work.bottom) - height);
    SetWindowPos(overlay_, HWND_TOPMOST, left, top, width, height, SWP_NOACTIVATE);
    RenderOverlay();
  }

  void SavePlacement() {
    if (!overlay_) return;
    RECT bounds{};
    if (!GetWindowRect(overlay_, &bounds)) return;
    HKEY settings = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegistryKey, 0, nullptr, 0, KEY_WRITE,
                       nullptr, &settings, nullptr) == ERROR_SUCCESS) {
      RegSetValueExW(settings, L"OverlayBounds", 0, REG_BINARY,
                      reinterpret_cast<const BYTE*>(&bounds), sizeof(bounds));
      RegCloseKey(settings);
    }
  }

  void SetClickThrough(bool enabled) {
    click_through_ = enabled;
    if (!overlay_) return;
    LONG_PTR style = GetWindowLongPtrW(overlay_, GWL_EXSTYLE);
    if (enabled) style |= WS_EX_TRANSPARENT;
    else style &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
    SetWindowLongPtrW(overlay_, GWL_EXSTYLE, style);
    SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, 0, 0,
                  SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }

  void ShowOverlay() {
    CreateOverlay();
    ClampOverlay();
    ShowWindow(overlay_, SW_SHOWNOACTIVATE);
    SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    RenderOverlay();
  }

  void ToggleOverlay() {
    if (overlay_ && IsWindowVisible(overlay_)) ShowWindow(overlay_, SW_HIDE);
    else ShowOverlay();
  }

  void ShowMain() {
    ShowWindow(main_, SW_RESTORE);
    SetForegroundWindow(main_);
  }

  void CreateTray() {
    taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
    NOTIFYICONDATAW tray{};
    tray.cbSize = sizeof(tray);
    tray.hWnd = main_;
    tray.uID = kTrayId;
    tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray.uCallbackMessage = kTrayMessage;
    tray.hIcon = reinterpret_cast<HICON>(SendMessageW(main_, WM_GETICON, ICON_SMALL, 0));
    if (!tray.hIcon) tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(tray.szTip, L"LumaCaption · 实时字幕");
    Shell_NotifyIconW(NIM_ADD, &tray);
    tray.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray);
  }

  void TrayMenu() {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, 1, L"打开 LumaCaption");
    AppendMenuW(menu, MF_STRING, 2, L"显示 / 隐藏字幕\tCtrl+Alt+L");
    AppendMenuW(menu, MF_STRING | (click_through_ ? MF_CHECKED : 0), 3, L"鼠标穿透（取消可恢复交互）");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 4, L"开始字幕");
    AppendMenuW(menu, MF_STRING, 5, L"停止字幕");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 6, L"退出 LumaCaption");
    POINT point{};
    GetCursorPos(&point);
    SetForegroundWindow(main_);
    const UINT selection = static_cast<UINT>(TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
        point.x, point.y, 0, main_, nullptr));
    DestroyMenu(menu);
    PostMessageW(main_, WM_NULL, 0, 0);
    if (selection == 1) ShowMain();
    if (selection == 2) ToggleOverlay();
    if (selection == 3) SetClickThrough(!click_through_);
    if (selection == 4 || selection == 5)
      Push(EncodableValue(EncodableMap{{EncodableValue("type"), EncodableValue("control")},
          {EncodableValue("action"), EncodableValue(selection == 4 ? "start" : "stop")}}));
    if (selection == 6) { quitting_ = true; Stop(); PostMessageW(main_, WM_CLOSE, 0, 0); }
  }

  EncodableValue Pick(const std::string& kind, const EncodableMap& args) {
    const bool save = kind == "saveText";
    ComPtr<IFileDialog> dialog;
    if (save) Check(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&dialog)), "Cannot open save dialog");
    else Check(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&dialog)), "Cannot open file dialog");
    DWORD options = 0;
    Check(dialog->GetOptions(&options), "Cannot inspect file dialog");
    options |= FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR;
    if (kind == "pickDirectory") options |= FOS_PICKFOLDERS;
    else if (!save) options |= FOS_FILEMUSTEXIST;
    else options |= FOS_OVERWRITEPROMPT;
    Check(dialog->SetOptions(options), "Cannot configure file dialog");
    const COMDLG_FILTERSPEC model[] = {{L"whisper.cpp GGML 模型", L"*.bin"}};
    const COMDLG_FILTERSPEC audio[] = {{L"PCM WAV 音频", L"*.wav"}};
    const COMDLG_FILTERSPEC subtitles[] = {{L"字幕与文本", L"*.txt;*.srt;*.vtt"}};
    if (kind == "pickModel") dialog->SetFileTypes(1, model);
    if (kind == "pickAudio") dialog->SetFileTypes(1, audio);
    if (save) {
      dialog->SetFileTypes(1, subtitles);
      const std::wstring name = Wide(String(args, "suggestedName", String(args, "fileName", "LumaCaption.txt")));
      dialog->SetFileName(name.c_str());
      dialog->SetDefaultExtension(L"txt");
    }
    const HRESULT shown = dialog->Show(main_);
    if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return EncodableValue();
    Check(shown, "File dialog failed");
    ComPtr<IShellItem> item;
    Check(dialog->GetResult(&item), "Cannot read selected file");
    PWSTR raw_path = nullptr;
    Check(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path), "Cannot read selected path");
    const std::wstring path(raw_path);
    CoTaskMemFree(raw_path);
    if (save) {
      const std::string text = String(args, "text");
      std::ofstream output(std::filesystem::path(path), std::ios::binary | std::ios::trunc);
      output.write(text.data(), static_cast<std::streamsize>(text.size()));
      output.close();
      if (!output) throw NativeError("write_failed", "Cannot save the selected text file.");
    }
    return EncodableValue(Utf8(path));
  }

  EncodableValue Secret(const std::string& method, const EncodableMap& args) {
    const auto account = String(args, "account");
    if (account.empty() || account.size() > 128)
      throw NativeError("invalid_account", "Credential account must contain 1–128 bytes.");
    const auto target = Wide("LumaCaption/" + account);
    if (method == "secrets.read") {
      PCREDENTIALW credential = nullptr;
      if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        if (GetLastError() == ERROR_NOT_FOUND) return EncodableValue();
        throw NativeError("credential_error", "Windows Credential Manager could not read this credential.");
      }
      const std::string value(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
      SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
      CredFree(credential);
      return EncodableValue(value);
    }
    if (method == "secrets.delete") {
      if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND)
        throw NativeError("credential_error", "Windows Credential Manager could not delete this credential.");
      return EncodableValue(true);
    }
    auto value = String(args, "value");
    if (value.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE)
      throw NativeError("credential_too_large", "Credential exceeds Windows Credential Manager's size limit.");
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(target.c_str());
    credential.CredentialBlobSize = static_cast<DWORD>(value.size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(value.data());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.UserName = const_cast<LPWSTR>(L"LumaCaption");
    const BOOL written = CredWriteW(&credential, 0);
    SecureZeroMemory(value.data(), value.size());
    if (!written) throw NativeError("credential_error", "Windows Credential Manager could not save this credential.");
    return EncodableValue(true);
  }

  EncodableMap SystemSpeechStatus() {
    // This base flavor deliberately has no import dependency on experimental
    // Windows AI DLLs. Only a compiled AND runtime-tested optional flavor may
    // call GetReadyState / EnsureReadyAsync / TryCreateAsync.
    using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    const auto rtl_get_version = reinterpret_cast<RtlGetVersionFunction>(
        GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
    if (rtl_get_version) rtl_get_version(&version);
    UINT32 package_length = 0;
    const LONG package_result = GetCurrentPackageFullName(&package_length, nullptr);
    const bool packaged = package_result == ERROR_INSUFFICIENT_BUFFER;
    const bool supported_os = version.dwBuildNumber >= 26100;
    const std::string status = !supported_os ? "unsupportedOS" :
        !packaged ? "requiresPackageIdentity" : "experimental";
    return {{EncodableValue("available"), EncodableValue(false)},
        {EncodableValue("status"), EncodableValue(status)},
        {EncodableValue("code"), EncodableValue("sdkNotIntegrated")},
        {EncodableValue("reason"), EncodableValue(
            !supported_os ? "Windows AI Speech requires Windows 11 24H2 or later; use an installed whisper.cpp model." :
            !packaged ? "This Inno Setup base build has no MSIX package identity. Windows AI Speech is not integrated; use whisper.cpp." :
            "Windows AI Speech is not compiled into this build. SDK and captured-stream validation remain incomplete; use whisper.cpp.")},
        {EncodableValue("osBuild"), EncodableValue(static_cast<int32_t>(version.dwBuildNumber))},
        {EncodableValue("hasPackageIdentity"), EncodableValue(packaged)},
        {EncodableValue("modelState"), EncodableValue("notProbed")},
        {EncodableValue("hardwareState"), EncodableValue("notProbed")},
        {EncodableValue("experimental"), EncodableValue(true)}};
  }

  void ConfigureHotkey(const EncodableMap& args, const char* name, int id,
                       UINT default_key) {
    const auto* value = Field(args, name);
    if (!value) return;
    const auto* config = std::get_if<EncodableMap>(value);
    if (!config) throw NativeError("invalid_hotkey", "Hotkey configuration must be a map.");
    const UINT key = static_cast<UINT>(Number(*config, "key", default_key));
    const UINT modifiers = static_cast<UINT>(Number(*config, "modifiers", MOD_CONTROL | MOD_ALT));
    if (key > 255 || key == 0 || (modifiers & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) != 0)
      throw NativeError("invalid_hotkey", "Hotkey key or modifier is invalid.");
    UnregisterHotKey(main_, id);
    if (!RegisterHotKey(main_, id, modifiers | MOD_NOREPEAT, key))
      throw NativeError("hotkey_unavailable", "The shortcut is already used. Tray interaction recovery remains available.");
  }

  void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    try {
      const auto* parsed = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      const EncodableMap empty;
      const auto& args = parsed ? *parsed : empty;
      std::string method = call.method_name();
      if (method.rfind("audio.", 0) == 0) method = method.substr(6);
      if (method.rfind("files.", 0) == 0) method = method.substr(6);
      if (method == "devices") result->Success(EncodableValue(Devices()));
      else if (method == "permissions" || method == "permissions.request")
        result->Success(EncodableValue(EncodableMap{
            {EncodableValue("system"), EncodableValue("granted")},
            {EncodableValue("microphone"), EncodableValue("systemManaged")},
            {EncodableValue("detail"), EncodableValue("Desktop microphone permission is managed in Windows Settings. Capture verifies endpoint access; loopback cannot capture protected audio.")}}));
      else if (method == "start") { Start(String(args, "source", "system"), String(args, "deviceId")); result->Success(EncodableValue(true)); }
      else if (method == "pause") { paused_ = true; ClearAudioQueue(); result->Success(EncodableValue(true)); }
      else if (method == "resume") { paused_ = false; result->Success(EncodableValue(true)); }
      else if (method == "stop") { Stop(); result->Success(EncodableValue(true)); }
      else if (method == "status") result->Success(EncodableValue(EncodableMap{
          {EncodableValue("running"), EncodableValue(capturing_.load())}}));
      else if (method == "overlay.show") { ShowOverlay(); result->Success(EncodableValue(true)); }
      else if (method == "overlay.hide") { if (overlay_) ShowWindow(overlay_, SW_HIDE); result->Success(EncodableValue(true)); }
      else if (method == "overlay.status") result->Success(EncodableValue(EncodableMap{
          {EncodableValue("visible"), EncodableValue(overlay_ && IsWindowVisible(overlay_) != FALSE)},
          {EncodableValue("clickThrough"), EncodableValue(click_through_)},
          {EncodableValue("isKeyWindow"), EncodableValue(overlay_ && GetForegroundWindow() == overlay_)}}));
      else if (method == "overlay.recover") { SetClickThrough(false); ShowOverlay(); result->Success(EncodableValue(true)); }
      else if (method == "overlay.update") {
        original_ = Wide(String(args, "original").substr(0, 16384));
        translation_ = Wide(String(args, "translation").substr(0, 16384));
        RenderOverlay(); result->Success(EncodableValue(true));
      } else if (method == "overlay.configure") {
        const double font_size = Number(args, "fontSize", font_size_);
        const double opacity = Number(args, "opacity", opacity_);
        if (!std::isfinite(font_size) || !std::isfinite(opacity))
          throw NativeError("invalid_appearance", "Appearance values must be finite.");
        font_size_ = std::clamp(font_size, 12.0, 96.0);
        opacity_ = std::clamp(opacity, 0.0, 1.0);
        const auto display = String(args, "display", display_);
        if (display != "bilingual" && display != "original" && display != "translation")
          throw NativeError("invalid_appearance", "Unknown subtitle display mode.");
        display_ = display;
        SetClickThrough(Boolean(args, "clickThrough", click_through_));
        RenderOverlay(); result->Success(EncodableValue(true));
      } else if (method == "secrets.read" || method == "secrets.write" || method == "secrets.delete")
        result->Success(Secret(method, args));
      else if (method == "paths") {
        const auto support = std::filesystem::path(KnownFolder(FOLDERID_LocalAppData)) / L"LumaCaption";
        std::filesystem::create_directories(support);
        result->Success(EncodableValue(EncodableMap{
            {EncodableValue("support"), EncodableValue(Utf8(support.wstring()))},
            {EncodableValue("documents"), EncodableValue(Utf8(KnownFolder(FOLDERID_Documents)))}}));
      } else if (method == "freeBytes") {
        ULARGE_INTEGER free_bytes{};
        const auto path = Wide(String(args, "path"));
        if (!GetDiskFreeSpaceExW(path.c_str(), &free_bytes, nullptr, nullptr))
          throw NativeError("storage", "Cannot check free storage space.");
        result->Success(EncodableValue(static_cast<int64_t>(free_bytes.QuadPart)));
      } else if (method == "pickModel" || method == "pickAudio" || method == "pickDirectory" || method == "saveText")
        result->Success(Pick(method, args));
      else if (method == "openPath") {
        const auto path = Wide(String(args, "path"));
        if (path.empty() || !std::filesystem::exists(path))
          throw NativeError("path_missing", "The requested file or folder does not exist.");
        const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(main_, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        if (opened <= 32) throw NativeError("open_failed", "Windows could not open this file or folder.");
        result->Success(EncodableValue(true));
      } else if (method == "windowsAI.status" || method == "systemAsr.status" || method == "systemSpeech.status")
        result->Success(EncodableValue(SystemSpeechStatus()));
      else if (method == "hotkeys.configure") {
        ConfigureHotkey(args, "toggleOverlay", kToggleHotkey, 'L');
        ConfigureHotkey(args, "recoverInteraction", kRecoverHotkey, 'I');
        result->Success(EncodableValue(true));
      } else if (method == "app.quit") {
        result->Success(EncodableValue(true));
        quitting_ = true; Stop(); PostMessageW(main_, WM_CLOSE, 0, 0);
      } else result->NotImplemented();
    } catch (const NativeError& error) { result->Error(error.code, error.what()); }
    catch (const std::exception& error) { result->Error("native_error", error.what()); }
  }

  HWND main_ = nullptr;
  HWND overlay_ = nullptr;
  ULONG_PTR gdiplus_token_ = 0;
  UINT taskbar_created_ = 0;
  bool shutdown_ = false;
  bool quitting_ = false;
  bool click_through_ = false;
  double font_size_ = 28;
  double opacity_ = 0.78;
  std::string display_ = "bilingual";
  std::wstring original_, translation_;
  HANDLE stop_event_ = nullptr;
  std::thread capture_thread_;
  std::atomic<bool> paused_{false}, capturing_{false};
  std::mutex queue_mutex_;
  std::deque<EncodableValue> queue_;
  bool dispatch_pending_ = false;
  uint64_t dropped_ = 0;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
};

NativeBridge::NativeBridge(flutter::BinaryMessenger* messenger, HWND main_window)
    : impl_(std::make_unique<Impl>(messenger, main_window)) {}
NativeBridge::~NativeBridge() = default;
std::optional<LRESULT> NativeBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  return impl_->Message(message, wparam, lparam);
}
void NativeBridge::Shutdown() { impl_->Shutdown(); }

}  // namespace luma
