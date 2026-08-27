#pragma once

#include "capture/d3d_device.hpp"
#include "capture/display_catalog.hpp"

#include <functional>
#include <mutex>
#include <winrt/Windows.Graphics.Capture.h>
#include <wrl/client.h>

struct ID3D11Texture2D;

namespace doppelscreen {

class ScreenCapturer {
 public:
  using FrameHandler = std::function<void(Microsoft::WRL::ComPtr<ID3D11Texture2D>, int, int, std::int64_t)>;

  ScreenCapturer(D3DDevice& device, DisplayCatalog::Entry display);
  ~ScreenCapturer();

  void start(FrameHandler handler);
  void stop();
  void resize(int width, int height, int max_framerate);
  const DisplayInfo& display() const noexcept { return display_.info; }

 private:
  void create_pool(int width, int height);
  void on_frame(winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& sender,
                winrt::Windows::Foundation::IInspectable const&);

  D3DDevice& device_;
  DisplayCatalog::Entry display_;
  FrameHandler handler_;
  std::mutex mutex_;
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
  winrt::event_token frame_token_{};
  int width_{};
  int height_{};
  int native_width_{};
  int native_height_{};
  int max_framerate_{30};
  std::int64_t last_frame_100ns_{};
};

}  // namespace doppelscreen
