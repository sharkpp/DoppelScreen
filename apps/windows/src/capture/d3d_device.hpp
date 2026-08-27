#pragma once

#include <d3d11.h>
#include <wrl/client.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

namespace doppelscreen {

class D3DDevice {
 public:
  D3DDevice();

  ID3D11Device* device() const noexcept { return device_.Get(); }
  ID3D11DeviceContext* context() const noexcept { return context_.Get(); }
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device() const { return winrt_device_; }

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device_{nullptr};
};

}  // namespace doppelscreen
