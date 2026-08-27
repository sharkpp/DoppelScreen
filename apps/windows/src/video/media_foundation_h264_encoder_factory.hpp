#pragma once

#include "capture/d3d_device.hpp"

#include <api/video_codecs/video_encoder_factory.h>

namespace doppelscreen {

class MediaFoundationH264EncoderFactory final : public webrtc::VideoEncoderFactory {
 public:
  explicit MediaFoundationH264EncoderFactory(D3DDevice& device) : device_(device) {}
  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override;
  CodecSupport QueryCodecSupport(const webrtc::SdpVideoFormat& format,
                                 std::optional<std::string> scalability_mode,
                                 std::optional<webrtc::Resolution> resolution) const override;
  std::unique_ptr<webrtc::VideoEncoder> Create(const webrtc::Environment& environment,
                                               const webrtc::SdpVideoFormat& format) override;

 private:
  D3DDevice& device_;
};

}  // namespace doppelscreen
