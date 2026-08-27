#pragma once

#include "capture/d3d_device.hpp"
#include "core/protocol.hpp"
#include "core/types.hpp"
#include "server/signaling_connection.hpp"

#include <api/data_channel_interface.h>
#include <api/peer_connection_interface.h>
#include <api/scoped_refptr.h>
#include <api/video/video_frame.h>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>

namespace webrtc { class Thread; }

namespace doppelscreen {

class MediaFoundationH264EncoderFactory;

class PeerTransport final : public webrtc::PeerConnectionObserver,
                            public webrtc::DataChannelObserver {
 public:
  using ControlHandler = std::function<void(protocol::ViewerControl)>;
  using ConnectedHandler = std::function<void()>;
  using FailureHandler = std::function<void(std::string)>;

  PeerTransport(D3DDevice& device, SignalingConnectionPtr signaling,
                DisplayInfo display, ControlHandler control, ConnectedHandler connected,
                FailureHandler failure);
  ~PeerTransport() override;

  bool start();
  void stop();
  void submit_frame(Microsoft::WRL::ComPtr<ID3D11Texture2D> texture,
                    int width, int height, std::int64_t timestamp_100ns);
  void handle_signal(const protocol::ViewerSignal& signal);
  void send_control(std::string message);
  void apply_quality(QualityPreset preset);

  void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState) override {}
  void OnAddStream(webrtc::scoped_refptr<webrtc::MediaStreamInterface>) override {}
  void OnRemoveStream(webrtc::scoped_refptr<webrtc::MediaStreamInterface>) override {}
  void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface>) override {}
  void OnRenegotiationNeeded() override {}
  void OnIceConnectionChange(webrtc::PeerConnectionInterface::IceConnectionState state) override;
  void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState) override {}
  void OnIceCandidate(const webrtc::IceCandidate* candidate) override;
  void OnIceConnectionReceivingChange(bool) override {}
  void OnConnectionChange(webrtc::PeerConnectionInterface::PeerConnectionState state) override;

  void OnStateChange() override;
  void OnMessage(const webrtc::DataBuffer& buffer) override;
  void OnBufferedAmountChange(uint64_t) override {}

 private:
  class VideoSource;
  class CreateOfferObserver;
  class SetLocalObserver;
  class SetRemoteObserver;

  void create_offer();
  void send_offer(std::string sdp);
  void fail(std::string code);

  D3DDevice& device_;
  SignalingConnectionPtr signaling_;
  DisplayInfo display_;
  ControlHandler control_handler_;
  ConnectedHandler connected_handler_;
  FailureHandler failure_handler_;
  std::unique_ptr<webrtc::Thread> network_thread_;
  std::unique_ptr<webrtc::Thread> worker_thread_;
  std::unique_ptr<webrtc::Thread> signaling_thread_;
  webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> factory_;
  webrtc::scoped_refptr<webrtc::PeerConnectionInterface> peer_;
  webrtc::scoped_refptr<webrtc::DataChannelInterface> control_;
  webrtc::scoped_refptr<VideoSource> source_;
  webrtc::scoped_refptr<webrtc::RtpSenderInterface> sender_;
  std::mutex control_mutex_;
  std::deque<std::string> pending_control_;
  std::mutex signaling_mutex_;
  std::deque<std::string> pending_candidates_;
  bool offer_sent_{};
  QualityPreset quality_{QualityPreset::sharp};
};

}  // namespace doppelscreen
