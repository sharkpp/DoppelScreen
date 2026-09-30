#pragma once

#include "generated/host_api.g.h"
#include "session/session_controller.hpp"

#include <flutter/binary_messenger.h>

namespace doppelscreen {

// ホスト UI（Flutter、apps/host_ui）と SessionController の境界（docs/adr/0002-host-ui-flutter.md）。
// 型と通信路は Pigeon の生成物（generated/host_api.g.h）で、ここが担うのは写し替えだけ。
// 跨ぐのは状態と操作に限り、判断はすべて SessionController が持つ。UI スレッドからだけ呼ぶ。
class HostBridge final : public ui::HostUIControl {
 public:
  HostBridge(flutter::BinaryMessenger* messenger, SessionController& controller, int language);
  ~HostBridge() override;

  // 状態を丸ごと送り直す。変化したときと、トークンの残り時間を進める 1 秒ごとに呼ぶ
  void publish();

  ui::ErrorOr<ui::HostState> CurrentState() override;
  std::optional<ui::FlutterError> StartServing() override;
  std::optional<ui::FlutterError> StopServing() override;
  std::optional<ui::FlutterError> RegenerateToken() override;
  std::optional<ui::FlutterError> Approve(int64_t display_id) override;
  std::optional<ui::FlutterError> Reject(int64_t display_id) override;
  std::optional<ui::FlutterError> Disconnect(int64_t display_id) override;
  // Windows には画面収録の許可の仕組みがない。状態は常に granted で、これらは呼ばれない
  std::optional<ui::FlutterError> RequestPermission() override;
  std::optional<ui::FlutterError> OpenPermissionSettings() override;
  std::optional<ui::FlutterError> Relaunch() override;

 private:
  ui::HostState state();

  flutter::BinaryMessenger* messenger_;
  SessionController& controller_;
  ui::HostUIEvents events_;
  int language_;
};

}  // namespace doppelscreen
