#include "video/media_foundation_h264_encoder_factory.hpp"

#include "video/media_foundation_h264_encoder.hpp"

#include <api/video_codecs/h264_profile_level_id.h>
#include <api/video_codecs/sdp_video_format.h>

namespace doppelscreen {

std::vector<webrtc::SdpVideoFormat> MediaFoundationH264EncoderFactory::GetSupportedFormats() const {
  // The encoder produces High Profile. 640c34 advertises Constrained High,
  // which Chrome cannot match to its High Profile receiver capability.
  return {{"H264", {{"profile-level-id", "640034"},
                    {"level-asymmetry-allowed", "1"},
                    {"packetization-mode", "1"}}}};
}

webrtc::VideoEncoderFactory::CodecSupport MediaFoundationH264EncoderFactory::QueryCodecSupport(
    const webrtc::SdpVideoFormat& format, std::optional<std::string>,
    std::optional<webrtc::Resolution>) const {
  return {.is_supported = format.name == "H264" || format.name == "h264",
          .is_power_efficient = true};
}

std::unique_ptr<webrtc::VideoEncoder> MediaFoundationH264EncoderFactory::Create(
    const webrtc::Environment&, const webrtc::SdpVideoFormat& format) {
  if (!QueryCodecSupport(format, std::nullopt, std::nullopt).is_supported) return nullptr;
  return std::make_unique<MediaFoundationH264Encoder>(device_);
}

}  // namespace doppelscreen
