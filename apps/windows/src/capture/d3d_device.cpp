#include "capture/d3d_device.hpp"

#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/base.h>

namespace doppelscreen {

D3DDevice::D3DDevice() {
  constexpr UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  constexpr D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
  D3D_FEATURE_LEVEL selected{};
  winrt::check_hresult(D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, std::size(levels),
      D3D11_SDK_VERSION, device_.Put(), &selected, context_.Put()));

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
  winrt::check_hresult(device_.As(&dxgi));
  winrt::com_ptr<IInspectable> inspectable;
  winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put()));
  winrt_device_ = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
}

}  // namespace doppelscreen
