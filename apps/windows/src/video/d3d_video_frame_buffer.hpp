#pragma once

#include <api/scoped_refptr.h>
#include <api/video/video_frame_buffer.h>
#include <d3d11.h>
#include <wrl/client.h>

namespace doppelscreen {

class D3DVideoFrameBuffer : public webrtc::VideoFrameBuffer {
 public:
  D3DVideoFrameBuffer(Microsoft::WRL::ComPtr<ID3D11Texture2D> texture, int width, int height);
  Type type() const override { return Type::kNative; }
  int width() const override { return width_; }
  int height() const override { return height_; }
  webrtc::scoped_refptr<webrtc::I420BufferInterface> ToI420() override;
  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> CropAndScale(int offset_x, int offset_y,
                                                    int crop_width, int crop_height,
                                                    int scaled_width, int scaled_height) override;
  ID3D11Texture2D* texture() const noexcept { return texture_.Get(); }

 private:
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture_;
  int width_;
  int height_;
};

}  // namespace doppelscreen
