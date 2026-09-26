#include "video/media_foundation_h264_encoder.hpp"

#include "video/d3d_video_frame_buffer.hpp"

#include <api/video/encoded_image.h>
#include <codecapi.h>
#include <mferror.h>
#include <modules/video_coding/include/video_codec_interface.h>
#include <modules/video_coding/include/video_error_codes.h>
#include <wmcodecdsp.h>
#include <algorithm>
#include <chrono>

namespace doppelscreen {
using Microsoft::WRL::ComPtr;
namespace {
void set_u32(IMFAttributes* attributes, REFGUID key, UINT32 value) {
  if (attributes) attributes->SetUINT32(key, value);
}

void set_codec_u32(IMFTransform* transform, const GUID& key, ULONG value) {
  ComPtr<ICodecAPI> codec;
  if (FAILED(transform->QueryInterface(IID_PPV_ARGS(codec.ReleaseAndGetAddressOf())))) return;
  VARIANT setting;
  VariantInit(&setting);
  setting.vt = VT_UI4;
  setting.ulVal = value;
  codec->SetValue(&key, &setting);
  VariantClear(&setting);
}

bool wants_keyframe(const std::vector<webrtc::VideoFrameType>* types) {
  return types && std::find(types->begin(), types->end(), webrtc::VideoFrameType::kVideoFrameKey) != types->end();
}
}  // namespace

MediaFoundationH264Encoder::MediaFoundationH264Encoder(D3DDevice& device) : device_(device) {
  MFStartup(MF_VERSION, MFSTARTUP_LITE);
}

MediaFoundationH264Encoder::~MediaFoundationH264Encoder() {
  Release();
  MFShutdown();
}

int MediaFoundationH264Encoder::InitEncode(const webrtc::VideoCodec* codec, const Settings&) {
  if (!codec || codec->width < 2 || codec->height < 2) return WEBRTC_VIDEO_CODEC_ERR_PARAMETER;
  Release();
  width_ = codec->width;
  height_ = codec->height;
  framerate_ = std::max(1u, codec->maxFramerate);
  bitrate_bps_ = std::max(1u, codec->startBitrate) * 1000;
  if (!create_transform() || !configure_transform()) return WEBRTC_VIDEO_CODEC_ERROR;
  encoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  encoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  event_thread_ = std::jthread([this](std::stop_token stop) { event_loop(stop); });
  return WEBRTC_VIDEO_CODEC_OK;
}

int32_t MediaFoundationH264Encoder::RegisterEncodeCompleteCallback(
    webrtc::EncodedImageCallback* callback) {
  callback_ = callback;
  return WEBRTC_VIDEO_CODEC_OK;
}

int32_t MediaFoundationH264Encoder::Release() {
  if (event_thread_.joinable()) {
    event_thread_.request_stop();
    event_thread_.join();
  }
  if (encoder_) {
    encoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    encoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  }
  {
    std::scoped_lock lock(mutex_);
    pending_.clear();
    submitted_.clear();
    input_requests_ = 0;
  }
  events_.Reset();
  encoder_.Reset();
  processor_.Reset();
  processor_enumerator_.Reset();
  processor_input_width_ = 0;
  processor_input_height_ = 0;
  video_context_.Reset();
  video_device_.Reset();
  device_manager_.Reset();
  return WEBRTC_VIDEO_CODEC_OK;
}

int32_t MediaFoundationH264Encoder::Encode(
    const webrtc::VideoFrame& frame,
    const std::vector<webrtc::VideoFrameType>* frame_types) {
  if (!encoder_ || !callback_) return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
  auto* native = dynamic_cast<D3DVideoFrameBuffer*>(frame.video_frame_buffer().get());
  if (!native) return WEBRTC_VIDEO_CODEC_ERR_PARAMETER;
  // WebRTC uses microseconds; Media Foundation sample times use 100-nanosecond units.
  auto sample = make_input_sample(native->texture(), frame.timestamp_us() * 10);
  if (!sample) return WEBRTC_VIDEO_CODEC_ERROR;
  const auto keyframe = wants_keyframe(frame_types);
  if (keyframe) set_codec_u32(encoder_.Get(), CODECAPI_AVEncVideoForceKeyFrame, TRUE);
  {
    std::scoped_lock lock(mutex_);
    if (pending_.size() >= 2) pending_.pop_front();
    pending_.push_back({std::move(sample), frame.rtp_timestamp(), keyframe});
  }
  provide_input();
  return WEBRTC_VIDEO_CODEC_OK;
}

void MediaFoundationH264Encoder::SetRates(const RateControlParameters& parameters) {
  bitrate_bps_ = static_cast<std::uint32_t>(parameters.bitrate.get_sum_bps());
  framerate_ = std::max(1, static_cast<int>(parameters.framerate_fps + 0.5));
  update_bitrate();
}

webrtc::VideoEncoder::EncoderInfo MediaFoundationH264Encoder::GetEncoderInfo() const {
  EncoderInfo info;
  info.implementation_name = "MediaFoundation-H264";
  info.is_hardware_accelerated = true;
  info.supports_native_handle = true;
  info.has_trusted_rate_controller = true;
  return info;
}

bool MediaFoundationH264Encoder::create_transform() {
  MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO output{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activations = nullptr;
  UINT32 count = 0;
  const auto result = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
      MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_LOCALMFT,
      &input, &output, &activations, &count);
  if (FAILED(result) || count == 0) return false;
  const auto activate_result =
      activations[0]->ActivateObject(IID_PPV_ARGS(encoder_.ReleaseAndGetAddressOf()));
  for (UINT32 index = 0; index < count; ++index) activations[index]->Release();
  CoTaskMemFree(activations);
  if (FAILED(activate_result)) return false;
  return SUCCEEDED(encoder_.As(&events_));
}

bool MediaFoundationH264Encoder::configure_transform() {
  ComPtr<IMFAttributes> attributes;
  if (FAILED(encoder_->GetAttributes(attributes.ReleaseAndGetAddressOf()))) return false;
  set_u32(attributes.Get(), MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
  set_u32(attributes.Get(), MF_LOW_LATENCY, TRUE);

  UINT reset_token = 0;
  if (FAILED(MFCreateDXGIDeviceManager(&reset_token, device_manager_.ReleaseAndGetAddressOf())) ||
      FAILED(device_manager_->ResetDevice(device_.device(), reset_token)) ||
      FAILED(encoder_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                      reinterpret_cast<ULONG_PTR>(device_manager_.Get())))) return false;

  DWORD inputs = 0;
  DWORD outputs = 0;
  if (FAILED(encoder_->GetStreamCount(&inputs, &outputs)) || inputs != 1 || outputs != 1) return false;
  input_stream_ = output_stream_ = 0;
  DWORD input_id = 0;
  DWORD output_id = 0;
  if (SUCCEEDED(encoder_->GetStreamIDs(1, &input_id, 1, &output_id))) {
    input_stream_ = input_id;
    output_stream_ = output_id;
  }

  ComPtr<IMFMediaType> output_type;
  MFCreateMediaType(output_type.ReleaseAndGetAddressOf());
  output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  MFSetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE, width_, height_);
  MFSetAttributeRatio(output_type.Get(), MF_MT_FRAME_RATE, framerate_, 1);
  MFSetAttributeRatio(output_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  output_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate_bps_);
  output_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  output_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
  output_type->SetUINT32(MF_MT_MPEG2_LEVEL, eAVEncH264VLevel5_2);
  if (FAILED(encoder_->SetOutputType(output_stream_, output_type.Get(), 0))) return false;

  ComPtr<IMFMediaType> input_type;
  MFCreateMediaType(input_type.ReleaseAndGetAddressOf());
  input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(input_type.Get(), MF_MT_FRAME_SIZE, width_, height_);
  MFSetAttributeRatio(input_type.Get(), MF_MT_FRAME_RATE, framerate_, 1);
  MFSetAttributeRatio(input_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  input_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (FAILED(encoder_->SetInputType(input_stream_, input_type.Get(), 0))) return false;

  set_codec_u32(encoder_.Get(), CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_LowDelayVBR);
  set_codec_u32(encoder_.Get(), CODECAPI_AVEncCommonMeanBitRate, bitrate_bps_);
  set_codec_u32(encoder_.Get(), CODECAPI_AVEncMPVGOPSize, framerate_ * 60);
  set_codec_u32(encoder_.Get(), CODECAPI_AVLowLatencyMode, TRUE);
  return true;
}

ComPtr<ID3D11Texture2D> MediaFoundationH264Encoder::convert_to_nv12(ID3D11Texture2D* texture) {
  D3D11_TEXTURE2D_DESC description{};
  texture->GetDesc(&description);
  const auto source_width = static_cast<LONG>(description.Width);
  const auto source_height = static_cast<LONG>(description.Height);
  if (!video_device_ || processor_input_width_ != description.Width ||
      processor_input_height_ != description.Height) {
    if (FAILED(device_.device()->QueryInterface(
            IID_PPV_ARGS(video_device_.ReleaseAndGetAddressOf()))) ||
        FAILED(device_.context()->QueryInterface(
            IID_PPV_ARGS(video_context_.ReleaseAndGetAddressOf())))) return {};
    processor_.Reset();
    processor_enumerator_.Reset();
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC description{};
    description.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    description.InputWidth = source_width;
    description.InputHeight = source_height;
    description.OutputWidth = width_;
    description.OutputHeight = height_;
    description.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    if (FAILED(video_device_->CreateVideoProcessorEnumerator(
            &description, processor_enumerator_.ReleaseAndGetAddressOf())) ||
        FAILED(video_device_->CreateVideoProcessor(
            processor_enumerator_.Get(), 0, processor_.ReleaseAndGetAddressOf()))) return {};
    processor_input_width_ = source_width;
    processor_input_height_ = source_height;
  }
  description.Width = width_;
  description.Height = height_;
  description.Format = DXGI_FORMAT_NV12;
  description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  description.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> output;
  if (FAILED(device_.device()->CreateTexture2D(
          &description, nullptr, output.ReleaseAndGetAddressOf()))) return {};
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input_description{};
  input_description.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  input_description.Texture2D.ArraySlice = 0;
  ComPtr<ID3D11VideoProcessorInputView> input_view;
  if (FAILED(video_device_->CreateVideoProcessorInputView(texture, processor_enumerator_.Get(),
                                                           &input_description,
                                                           input_view.ReleaseAndGetAddressOf()))) return {};
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output_description{};
  output_description.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  ComPtr<ID3D11VideoProcessorOutputView> output_view;
  if (FAILED(video_device_->CreateVideoProcessorOutputView(output.Get(), processor_enumerator_.Get(),
                                                             &output_description,
                                                             output_view.ReleaseAndGetAddressOf()))) return {};
  RECT source{0, 0, source_width, source_height};
  RECT destination{0, 0, width_, height_};
  video_context_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &source);
  video_context_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &destination);
  D3D11_VIDEO_PROCESSOR_STREAM stream{};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view.Get();
  if (FAILED(video_context_->VideoProcessorBlt(processor_.Get(), output_view.Get(), 0, 1, &stream))) return {};
  return output;
}

ComPtr<IMFSample> MediaFoundationH264Encoder::make_input_sample(ID3D11Texture2D* texture,
                                                                std::int64_t timestamp_100ns) {
  auto nv12 = convert_to_nv12(texture);
  if (!nv12) return {};
  ComPtr<IMFMediaBuffer> buffer;
  if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12.Get(), 0, FALSE,
                                       buffer.ReleaseAndGetAddressOf()))) return {};
  ComPtr<IMFSample> sample;
  if (FAILED(MFCreateSample(sample.ReleaseAndGetAddressOf())) ||
      FAILED(sample->AddBuffer(buffer.Get()))) return {};
  sample->SetSampleTime(timestamp_100ns);
  sample->SetSampleDuration(10'000'000 / std::max(1, framerate_));
  return sample;
}

void MediaFoundationH264Encoder::event_loop(std::stop_token stop) {
  while (!stop.stop_requested() && events_) {
    ComPtr<IMFMediaEvent> event;
    const auto result = events_->GetEvent(MF_EVENT_FLAG_NO_WAIT,
                                          event.ReleaseAndGetAddressOf());
    if (result == MF_E_NO_EVENTS_AVAILABLE) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    if (FAILED(result)) break;
    MediaEventType type{};
    event->GetType(&type);
    if (type == METransformNeedInput) {
      {
        std::scoped_lock lock(mutex_);
        ++input_requests_;
      }
      provide_input();
    }
    if (type == METransformHaveOutput) collect_output();
  }
}

void MediaFoundationH264Encoder::provide_input() {
  std::scoped_lock input_lock(input_mutex_);
  PendingFrame frame;
  {
    std::scoped_lock lock(mutex_);
    if (pending_.empty() || input_requests_ == 0) return;
    frame = std::move(pending_.front());
    pending_.pop_front();
    --input_requests_;
  }
  if (SUCCEEDED(encoder_->ProcessInput(input_stream_, frame.sample.Get(), 0))) {
    std::scoped_lock lock(mutex_);
    submitted_.push_back(std::move(frame));
  } else {
    std::scoped_lock lock(mutex_);
    ++input_requests_;
  }
}

void MediaFoundationH264Encoder::collect_output() {
  MFT_OUTPUT_STREAM_INFO info{};
  if (FAILED(encoder_->GetOutputStreamInfo(output_stream_, &info))) return;
  ComPtr<IMFSample> sample;
  if ((info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, 4 * 1024 * 1024),
                                    buffer.ReleaseAndGetAddressOf())) ||
        FAILED(MFCreateSample(sample.ReleaseAndGetAddressOf())) ||
        FAILED(sample->AddBuffer(buffer.Get()))) return;
  }
  MFT_OUTPUT_DATA_BUFFER output{};
  output.dwStreamID = output_stream_;
  output.pSample = sample.Get();
  DWORD status = 0;
  const auto result = encoder_->ProcessOutput(0, 1, &output, &status);
  if (output.pEvents) output.pEvents->Release();
  if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
    // Hardware MFTs can revise the output format after the first input sample.
    ComPtr<IMFMediaType> type;
    if (SUCCEEDED(encoder_->GetOutputAvailableType(
            output_stream_, 0, type.ReleaseAndGetAddressOf())))
      encoder_->SetOutputType(output_stream_, type.Get(), 0);
    return;
  }
  if (FAILED(result) || !output.pSample) return;

  ComPtr<IMFMediaBuffer> contiguous;
  if (FAILED(output.pSample->ConvertToContiguousBuffer(
          contiguous.ReleaseAndGetAddressOf()))) return;
  BYTE* bytes = nullptr;
  DWORD length = 0;
  if (FAILED(contiguous->Lock(&bytes, nullptr, &length))) return;
  auto encoded_data = webrtc::EncodedImageBuffer::Create(bytes, length);
  contiguous->Unlock();
  PendingFrame frame;
  {
    std::scoped_lock lock(mutex_);
    if (submitted_.empty()) return;
    frame = std::move(submitted_.front());
    submitted_.pop_front();
  }
  UINT32 clean_point = 0;
  output.pSample->GetUINT32(MFSampleExtension_CleanPoint, &clean_point);
  webrtc::EncodedImage image;
  image.SetEncodedData(std::move(encoded_data));
  image.SetRtpTimestamp(frame.timestamp);
  image._encodedWidth = width_;
  image._encodedHeight = height_;
  image._frameType = clean_point ? webrtc::VideoFrameType::kVideoFrameKey
                                 : webrtc::VideoFrameType::kVideoFrameDelta;
  webrtc::CodecSpecificInfo codec_info;
  codec_info.codecType = webrtc::kVideoCodecH264;
  codec_info.codecSpecific.H264.packetization_mode = webrtc::H264PacketizationMode::NonInterleaved;
  if (callback_) callback_->OnEncodedImage(image, &codec_info);
  if (output.pSample != sample.Get()) output.pSample->Release();
}

void MediaFoundationH264Encoder::update_bitrate() {
  if (encoder_) set_codec_u32(encoder_.Get(), CODECAPI_AVEncCommonMeanBitRate, bitrate_bps_);
}

}  // namespace doppelscreen
