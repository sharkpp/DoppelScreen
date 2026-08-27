#pragma once

#include "capture/d3d_device.hpp"

#include <api/video_codecs/video_encoder.h>
#include <mfapi.h>
#include <mfidl.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <deque>
#include <mutex>
#include <thread>

namespace doppelscreen {

class MediaFoundationH264Encoder final : public webrtc::VideoEncoder {
 public:
  explicit MediaFoundationH264Encoder(D3DDevice& device);
  ~MediaFoundationH264Encoder() override;

  int InitEncode(const webrtc::VideoCodec* codec, const Settings& settings) override;
  int32_t RegisterEncodeCompleteCallback(webrtc::EncodedImageCallback* callback) override;
  int32_t Release() override;
  int32_t Encode(const webrtc::VideoFrame& frame,
                 const std::vector<webrtc::VideoFrameType>* frame_types) override;
  void SetRates(const RateControlParameters& parameters) override;
  EncoderInfo GetEncoderInfo() const override;

 private:
  struct PendingFrame { Microsoft::WRL::ComPtr<IMFSample> sample; std::uint32_t timestamp; bool keyframe; };

  bool create_transform();
  bool configure_transform();
  Microsoft::WRL::ComPtr<IMFSample> make_input_sample(ID3D11Texture2D* texture,
                                                       std::int64_t timestamp_100ns);
  Microsoft::WRL::ComPtr<ID3D11Texture2D> convert_to_nv12(ID3D11Texture2D* texture);
  void event_loop(std::stop_token stop);
  void provide_input();
  void collect_output();
  void update_bitrate();

  D3DDevice& device_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> device_manager_;
  Microsoft::WRL::ComPtr<IMFTransform> encoder_;
  Microsoft::WRL::ComPtr<IMFMediaEventGenerator> events_;
  Microsoft::WRL::ComPtr<ID3D11VideoDevice> video_device_;
  Microsoft::WRL::ComPtr<ID3D11VideoContext> video_context_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> processor_enumerator_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessor> processor_;
  webrtc::EncodedImageCallback* callback_{};
  std::jthread event_thread_;
  std::mutex mutex_;
  std::mutex input_mutex_;
  std::deque<PendingFrame> pending_;
  std::deque<PendingFrame> submitted_;
  int input_requests_{};
  int width_{};
  int height_{};
  int framerate_{30};
  std::uint32_t bitrate_bps_{20'000'000};
  DWORD input_stream_{};
  DWORD output_stream_{};
  UINT processor_input_width_{};
  UINT processor_input_height_{};
};

}  // namespace doppelscreen
