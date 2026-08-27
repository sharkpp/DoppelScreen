#include "video/d3d_video_frame_buffer.hpp"

#include <api/make_ref_counted.h>
#include <utility>

namespace doppelscreen {

D3DVideoFrameBuffer::D3DVideoFrameBuffer(Microsoft::WRL::ComPtr<ID3D11Texture2D> texture,
                                         int width, int height)
    : texture_(std::move(texture)), width_(width), height_(height) {}

webrtc::scoped_refptr<webrtc::I420BufferInterface> D3DVideoFrameBuffer::ToI420() { return nullptr; }

webrtc::scoped_refptr<webrtc::VideoFrameBuffer> D3DVideoFrameBuffer::CropAndScale(
    int offset_x, int offset_y, int crop_width, int crop_height,
    int scaled_width, int scaled_height) {
  if (offset_x == 0 && offset_y == 0 && crop_width == width_ && crop_height == height_ &&
      scaled_width == width_ && scaled_height == height_) {
    return webrtc::scoped_refptr<webrtc::VideoFrameBuffer>(this);
  }
  return nullptr;
}

}  // namespace doppelscreen
