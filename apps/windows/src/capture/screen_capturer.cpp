#include "capture/screen_capturer.hpp"

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/base.h>
#include <utility>

namespace doppelscreen {
using namespace winrt::Windows::Graphics;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
namespace {
GraphicsCaptureItem item_for_monitor(HMONITOR monitor) {
  auto interop = winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
  GraphicsCaptureItem item{nullptr};
  winrt::check_hresult(interop->CreateForMonitor(monitor, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item)));
  return item;
}

Microsoft::WRL::ComPtr<ID3D11Texture2D> texture_from_surface(
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface const& surface) {
  auto access = surface.as<IDirect3DDxgiInterfaceAccess>();
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(texture.Put())));
  return texture;
}
}  // namespace

ScreenCapturer::ScreenCapturer(D3DDevice& device, DisplayCatalog::Entry display)
    : device_(device), display_(std::move(display)), item_(item_for_monitor(display_.monitor)),
      width_(display_.info.width), height_(display_.info.height),
      native_width_(display_.info.width), native_height_(display_.info.height) {}

ScreenCapturer::~ScreenCapturer() { stop(); }

void ScreenCapturer::start(FrameHandler handler) {
  std::scoped_lock lock(mutex_);
  if (session_) return;
  handler_ = std::move(handler);
  create_pool(native_width_, native_height_);
  session_ = pool_.CreateCaptureSession(item_);
  session_.IsCursorCaptureEnabled(true);
  session_.StartCapture();
}

void ScreenCapturer::stop() {
  GraphicsCaptureSession session{nullptr};
  Direct3D11CaptureFramePool pool{nullptr};
  winrt::event_token token{};
  {
    std::scoped_lock lock(mutex_);
    session = std::exchange(session_, nullptr);
    pool = std::exchange(pool_, nullptr);
    token = frame_token_;
    frame_token_ = {};
    handler_ = {};
  }
  if (pool) pool.FrameArrived(token);
  if (session) session.Close();
  if (pool) pool.Close();
}

void ScreenCapturer::resize(int width, int height, int max_framerate) {
  std::scoped_lock lock(mutex_);
  width_ = width;
  height_ = height;
  max_framerate_ = max_framerate;
  last_frame_100ns_ = 0;
}

void ScreenCapturer::create_pool(int width, int height) {
  pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(
      device_.winrt_device(), DirectXPixelFormat::B8G8R8A8UIntNormalized, 3, {width, height});
  frame_token_ = pool_.FrameArrived({this, &ScreenCapturer::on_frame});
}

void ScreenCapturer::on_frame(Direct3D11CaptureFramePool const& sender,
                              winrt::Windows::Foundation::IInspectable const&) {
  auto frame = sender.TryGetNextFrame();
  if (!frame) return;
  const auto timestamp = frame.SystemRelativeTime().count();
  const auto content_size = frame.ContentSize();
  auto texture = texture_from_surface(frame.Surface());
  frame.Close();
  FrameHandler handler;
  int width = 0;
  int height = 0;
  {
    std::scoped_lock lock(mutex_);
    const auto minimum_interval = 10'000'000 / std::max(1, max_framerate_);
    if (last_frame_100ns_ && timestamp - last_frame_100ns_ < minimum_interval) return;
    last_frame_100ns_ = timestamp;
    if (pool_ && content_size.Width > 0 && content_size.Height > 0 &&
        (content_size.Width != native_width_ || content_size.Height != native_height_)) {
      sender.Recreate(device_.winrt_device(), DirectXPixelFormat::B8G8R8A8UIntNormalized,
                      3, content_size);
      native_width_ = content_size.Width;
      native_height_ = content_size.Height;
    }
    handler = handler_;
    width = width_;
    height = height_;
  }
  if (handler) handler(std::move(texture), width, height, timestamp);
}

}  // namespace doppelscreen
