#include "video/peer_transport.hpp"

#include "core/video_encoding.hpp"
#include "video/d3d_video_frame_buffer.hpp"
#include "video/media_foundation_h264_encoder_factory.hpp"

#include <api/create_peerconnection_factory.h>
#include <api/jsep.h>
#include <api/make_ref_counted.h>
#include <api/rtp_parameters.h>
#include <api/set_local_description_observer_interface.h>
#include <api/set_remote_description_observer_interface.h>
#include <api/transport/bitrate_settings.h>
#include <api/video/adapted_video_track_source.h>
#include <api/video_codecs/builtin_video_decoder_factory.h>
#include <rtc_base/thread.h>

namespace doppelscreen {

class PeerTransport::VideoSource final : public webrtc::AdaptedVideoTrackSource {
 public:
  SourceState state() const override { return SourceState::kLive; }
  bool remote() const override { return false; }
  bool is_screencast() const override { return true; }
  std::optional<bool> needs_denoising() const override { return false; }
  void push(const webrtc::VideoFrame& frame) { OnFrame(frame); }
};

class PeerTransport::SetLocalObserver final : public webrtc::SetLocalDescriptionObserverInterface {
 public:
  SetLocalObserver(PeerTransport* owner, std::string sdp)
      : owner_(owner), sdp_(std::move(sdp)) {}
  void OnSetLocalDescriptionComplete(webrtc::RTCError error) override {
    if (!error.ok()) return owner_->fail("peer_failed");
    owner_->send_offer(std::move(sdp_));
  }
 private:
  PeerTransport* owner_;
  std::string sdp_;
};

class PeerTransport::SetRemoteObserver final : public webrtc::SetRemoteDescriptionObserverInterface {
 public:
  explicit SetRemoteObserver(PeerTransport* owner) : owner_(owner) {}
  void OnSetRemoteDescriptionComplete(webrtc::RTCError error) override {
    if (!error.ok()) owner_->fail("peer_failed");
  }
 private:
  PeerTransport* owner_;
};

class PeerTransport::CreateOfferObserver final : public webrtc::CreateSessionDescriptionObserver {
 public:
  explicit CreateOfferObserver(PeerTransport* owner) : owner_(owner) {}
  void OnSuccess(webrtc::SessionDescriptionInterface* description) override {
    std::string sdp;
    if (!description->ToString(&sdp)) {
      delete description;
      return owner_->fail("peer_failed");
    }
    owner_->peer_->SetLocalDescription(
        std::unique_ptr<webrtc::SessionDescriptionInterface>(description),
        webrtc::make_ref_counted<SetLocalObserver>(owner_, std::move(sdp)));
  }
  void OnFailure(webrtc::RTCError) override { owner_->fail("peer_failed"); }
 private:
  PeerTransport* owner_;
};

PeerTransport::PeerTransport(D3DDevice& device, SignalingConnectionPtr signaling,
                             DisplayInfo display, ControlHandler control, ConnectedHandler connected,
                             FailureHandler failure)
    : device_(device), signaling_(std::move(signaling)), display_(std::move(display)),
      control_handler_(std::move(control)), connected_handler_(std::move(connected)),
      failure_handler_(std::move(failure)) {}

PeerTransport::~PeerTransport() { stop(); }

bool PeerTransport::start() {
  network_thread_ = webrtc::Thread::CreateWithSocketServer();
  worker_thread_ = webrtc::Thread::Create();
  signaling_thread_ = webrtc::Thread::Create();
  if (!network_thread_->Start() || !worker_thread_->Start() || !signaling_thread_->Start()) return false;
  factory_ = webrtc::CreatePeerConnectionFactory(
      network_thread_.get(), worker_thread_.get(), signaling_thread_.get(), nullptr,
      nullptr, nullptr, std::make_unique<MediaFoundationH264EncoderFactory>(device_),
      webrtc::CreateBuiltinVideoDecoderFactory(), nullptr, nullptr);
  if (!factory_) return false;

  webrtc::PeerConnectionInterface::RTCConfiguration configuration;
  configuration.sdp_semantics = webrtc::SdpSemantics::kUnifiedPlan;
  configuration.type = webrtc::PeerConnectionInterface::kAll;
  auto result = factory_->CreatePeerConnectionOrError(
      configuration, webrtc::PeerConnectionDependencies(this));
  if (!result.ok()) return false;
  peer_ = result.MoveValue();

  source_ = webrtc::make_ref_counted<VideoSource>();
  auto track = factory_->CreateVideoTrack(source_, "screen");
  auto sender = peer_->AddTrack(track, {"screen"});
  if (!sender.ok()) return false;
  sender_ = sender.MoveValue();

  webrtc::DataChannelInit channel_configuration;
  channel_configuration.ordered = true;
  auto channel = peer_->CreateDataChannelOrError("control", &channel_configuration);
  if (!channel.ok()) return false;
  control_ = channel.MoveValue();
  control_->RegisterObserver(this);
  create_offer();
  return true;
}

void PeerTransport::stop() {
  webrtc::scoped_refptr<webrtc::DataChannelInterface> control;
  {
    std::scoped_lock lock(control_mutex_);
    control = std::move(control_);
    pending_control_.clear();
  }
  {
    std::scoped_lock lock(signaling_mutex_);
    pending_candidates_.clear();
    offer_sent_ = false;
  }
  if (control) control->UnregisterObserver();
  if (peer_) peer_->Close();
  sender_ = nullptr;
  source_ = nullptr;
  peer_ = nullptr;
  factory_ = nullptr;
  if (signaling_thread_) signaling_thread_->Stop();
  if (worker_thread_) worker_thread_->Stop();
  if (network_thread_) network_thread_->Stop();
  signaling_thread_.reset();
  worker_thread_.reset();
  network_thread_.reset();
}

void PeerTransport::submit_frame(Microsoft::WRL::ComPtr<ID3D11Texture2D> texture,
                                 int width, int height, std::int64_t timestamp_100ns) {
  if (!source_) return;
  auto buffer = webrtc::make_ref_counted<D3DVideoFrameBuffer>(std::move(texture), width, height);
  auto frame = webrtc::VideoFrame::Builder()
      .set_video_frame_buffer(std::move(buffer))
      .set_timestamp_us(timestamp_100ns / 10)
      .set_rotation(webrtc::kVideoRotation_0)
      .build();
  source_->push(frame);
}

void PeerTransport::handle_signal(const protocol::ViewerSignal& signal) {
  if (const auto* answer = std::get_if<protocol::ViewerAnswer>(&signal)) {
    webrtc::SdpParseError error;
    auto description = webrtc::CreateSessionDescription(webrtc::SdpType::kAnswer, answer->sdp, &error);
    if (!description) return fail("peer_failed");
    peer_->SetRemoteDescription(std::move(description),
                                webrtc::make_ref_counted<SetRemoteObserver>(this));
  } else if (const auto* candidate = std::get_if<protocol::IceCandidate>(&signal)) {
    webrtc::SdpParseError error;
    auto ice = webrtc::IceCandidate::Create(candidate->sdp_mid.value_or(""),
                                             candidate->sdp_mline_index.value_or(0),
                                             candidate->candidate, &error);
    if (ice) peer_->AddIceCandidate(ice.get());
  }
}

void PeerTransport::send_control(std::string message) {
  webrtc::scoped_refptr<webrtc::DataChannelInterface> control;
  {
    std::scoped_lock lock(control_mutex_);
    if (!control_ || control_->state() != webrtc::DataChannelInterface::kOpen) {
      pending_control_.push_back(std::move(message));
      return;
    }
    control = control_;
  }
  control->Send(webrtc::DataBuffer(message));
}

void PeerTransport::apply_quality(QualityPreset preset) {
  quality_ = preset;
  if (!sender_) return;
  auto parameters = sender_->GetParameters();
  const auto selected = video_encoding::settings(preset);
  webrtc::BitrateSettings bitrate;
  bitrate.min_bitrate_bps = video_encoding::min_bitrate_bps;
  bitrate.start_bitrate_bps = selected.max_bitrate_bps;
  bitrate.max_bitrate_bps = selected.max_bitrate_bps;
  peer_->SetBitrate(bitrate);
  parameters.degradation_preference = selected.maintain_resolution
      ? webrtc::DegradationPreference::MAINTAIN_RESOLUTION
      : webrtc::DegradationPreference::MAINTAIN_FRAMERATE;
  for (auto& encoding : parameters.encodings) {
    encoding.min_bitrate_bps = video_encoding::min_bitrate_bps;
    encoding.max_bitrate_bps = selected.max_bitrate_bps;
    encoding.max_framerate = selected.max_framerate;
    encoding.scale_resolution_down_by = 1.0;
  }
  sender_->SetParameters(parameters);
}

void PeerTransport::OnIceConnectionChange(
    webrtc::PeerConnectionInterface::IceConnectionState state) {
  if (state == webrtc::PeerConnectionInterface::kIceConnectionFailed) fail("peer_failed");
}

void PeerTransport::OnConnectionChange(
    webrtc::PeerConnectionInterface::PeerConnectionState state) {
  if (state == webrtc::PeerConnectionInterface::PeerConnectionState::kFailed) fail("peer_failed");
  if (state == webrtc::PeerConnectionInterface::PeerConnectionState::kConnected && connected_handler_) {
    connected_handler_();
  }
}

void PeerTransport::OnIceCandidate(const webrtc::IceCandidate* candidate) {
  auto message = protocol::encode_candidate(
      {candidate->ToString(), candidate->sdp_mid(), candidate->sdp_mline_index()});
  {
    std::scoped_lock lock(signaling_mutex_);
    if (!offer_sent_) {
      pending_candidates_.push_back(std::move(message));
      return;
    }
  }
  signaling_->send(std::move(message));
}

void PeerTransport::OnStateChange() {
  webrtc::scoped_refptr<webrtc::DataChannelInterface> control;
  {
    std::scoped_lock lock(control_mutex_);
    control = control_;
  }
  if (control && control->state() == webrtc::DataChannelInterface::kOpen) {
    send_control(protocol::encode_hello(display_));
    std::deque<std::string> pending;
    {
      std::scoped_lock lock(control_mutex_);
      pending.swap(pending_control_);
    }
    for (auto& message : pending) control->Send(webrtc::DataBuffer(message));
  }
}

void PeerTransport::OnMessage(const webrtc::DataBuffer& buffer) {
  const std::string text(reinterpret_cast<const char*>(buffer.data.data()), buffer.data.size());
  if (auto message = protocol::decode_viewer_control(text)) control_handler_(std::move(*message));
}

void PeerTransport::create_offer() {
  webrtc::PeerConnectionInterface::RTCOfferAnswerOptions options;
  options.offer_to_receive_audio = 0;
  options.offer_to_receive_video = 0;
  peer_->CreateOffer(webrtc::make_ref_counted<CreateOfferObserver>(this), options);
}

void PeerTransport::send_offer(std::string sdp) {
  std::deque<std::string> candidates;
  {
    std::scoped_lock lock(signaling_mutex_);
    offer_sent_ = true;
    candidates.swap(pending_candidates_);
  }
  apply_quality(quality_);
  signaling_->send(protocol::encode_offer(sdp));
  for (auto& candidate : candidates) signaling_->send(std::move(candidate));
}

void PeerTransport::fail(std::string code) {
  signaling_->send(protocol::encode_error(code));
  if (failure_handler_) failure_handler_(std::move(code));
}

}  // namespace doppelscreen
