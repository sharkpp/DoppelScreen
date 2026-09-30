#pragma once

#include "app/host_bridge.hpp"
#include "session/session_controller.hpp"

#include <windows.h>
#include <shellapi.h>
#include <flutter/flutter_view_controller.h>
#include <memory>

namespace doppelscreen {

// トップレベルのウィンドウと通知領域のアイコン。ウィンドウの中身は Flutter のホスト UI（apps/host_ui）が描く。
// Flutter エンジンはプロセスの寿命で 1 つだけ作り、ウィンドウを閉じても破棄しない
// （Dart VM はエンジンを捨ててもプロセスから抜けず、作り直すとかえって膨らむ。docs/adr/0002-host-ui-flutter.md）。
class MainWindow {
 public:
  explicit MainWindow(HINSTANCE instance);
  ~MainWindow();
  int run();

 private:
  static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT handle_message(UINT message, WPARAM wparam, LPARAM lparam);
  void show();
  void show_tray_menu();
  void apply_theme();
  std::filesystem::path viewer_path() const;

  HINSTANCE instance_{};
  HWND window_{};
  NOTIFYICONDATAW tray_{};
  std::unique_ptr<SessionController> controller_;
  std::unique_ptr<flutter::FlutterViewController> flutter_;
  std::unique_ptr<HostBridge> bridge_;
  int language_{};
  bool quitting_{};
};

}  // namespace doppelscreen
