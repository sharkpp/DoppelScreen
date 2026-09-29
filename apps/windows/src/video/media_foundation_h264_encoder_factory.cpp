#include "video/media_foundation_h264_encoder_factory.hpp"

#include "video/media_foundation_h264_encoder.hpp"

#include <api/video_codecs/h264_profile_level_id.h>
#include <api/video_codecs/sdp_video_format.h>

namespace doppelscreen {

std::vector<webrtc::SdpVideoFormat> MediaFoundationH264EncoderFactory::GetSupportedFormats() const {
  // Chrome advertises High; Safari advertises Constrained High or Baseline.
  // Keep the negotiated profile aligned with the Media Foundation output type.
  const auto format = [](const char* id) {
    return webrtc::SdpVideoFormat("H264", {{"profile-level-id", id},
                                           {"level-asymmetry-allowed", "1"},
                                           {"packetization-mode", "1"}});
  };
  return {format("640034"), format("640c34"), format("42e034")};
}

webrtc::VideoEncoderFactory::CodecSupport MediaFoundationH264EncoderFactory::QueryCodecSupport(
    const webrtc::SdpVideoFormat& format, std::optional<std::string>,
    std::optional<webrtc::Resolution>) const {
  const auto profile = webrtc::ParseSdpForH264ProfileLevelId(format.parameters);
  const bool supported = (format.name == "H264" || format.name == "h264") && profile &&
      (profile->profile == webrtc::H264Profile::kProfileHigh ||
       profile->profile == webrtc::H264Profile::kProfileConstrainedHigh ||
       profile->profile == webrtc::H264Profile::kProfileConstrainedBaseline);
  return {.is_supported = supported, .is_power_efficient = supported};
}

std::unique_ptr<webrtc::VideoEncoder> MediaFoundationH264EncoderFactory::Create(
    const webrtc::Environment&, const webrtc::SdpVideoFormat& format) {
  if (!QueryCodecSupport(format, std::nullopt, std::nullopt).is_supported) return nullptr;
  const auto profile = webrtc::ParseSdpForH264ProfileLevelId(format.parameters)->profile;
  const auto mf_profile = profile == webrtc::H264Profile::kProfileHigh
      ? eAVEncH264VProfile_High
      : profile == webrtc::H264Profile::kProfileConstrainedHigh
          ? eAVEncH264VProfile_ConstrainedHigh
          : eAVEncH264VProfile_ConstrainedBase;
  return std::make_unique<MediaFoundationH264Encoder>(device_, mf_profile);
}

}  // namespace doppelscreen
