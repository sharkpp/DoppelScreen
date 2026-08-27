#pragma once

#include "session/session_controller.hpp"

#include <windows.h>
#include <memory>

namespace doppelscreen {

class MainWindow {
 public:
  explicit MainWindow(HINSTANCE instance);
  ~MainWindow();
  int run();

 private:
  static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT handle_message(UINT message, WPARAM wparam, LPARAM lparam);
  void create_controls();
  void refresh();
  void layout();
  void paint(HDC dc);
  void show_tray_menu();
  void copy_primary_url();
  std::filesystem::path viewer_path() const;

  HINSTANCE instance_{};
  HWND window_{};
  HWND start_stop_{};
  HWND regenerate_{};
  HWND approve_{};
  HWND reject_{};
  HWND disconnect_{};
  HWND copy_url_{};
  NOTIFYICONDATAW tray_{};
  std::unique_ptr<SessionController> controller_;
  SessionController::Snapshot snapshot_;
  int language_{};
  bool quitting_{};
};

}  // namespace doppelscreen
