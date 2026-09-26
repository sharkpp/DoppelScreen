#pragma once

#include "session/session_controller.hpp"

#include <windows.h>
#include <shellapi.h>
#include <memory>
#include <vector>

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
  void rebuild_rows();
  void copy_url(std::string_view url);
  std::filesystem::path viewer_path() const;

  HINSTANCE instance_{};
  HWND window_{};
  HWND start_stop_{};
  HWND regenerate_{};
  HWND status_{};
  HWND token_{};
  struct UrlRow {
    HWND interface_label{};
    HWND edit{};
    HWND copy{};
    HWND qr{};
    std::string url;
  };
  struct DisplayRow {
    DisplayId id{};
    HWND heading{};
    HWND status{};
    HWND approve{};
    HWND reject{};
    HWND disconnect{};
    std::vector<UrlRow> urls;
  };
  std::vector<DisplayRow> rows_;
  std::vector<SessionController::Endpoint> displayed_endpoints_;
  std::vector<DisplayInfo> displayed_displays_;
  std::string expanded_url_;
  int scroll_offset_{};
  int content_height_{};
  NOTIFYICONDATAW tray_{};
  std::unique_ptr<SessionController> controller_;
  SessionController::Snapshot snapshot_;
  int language_{};
  bool quitting_{};
};

}  // namespace doppelscreen
