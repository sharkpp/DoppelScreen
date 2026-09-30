#include "app/main_window.hpp"

#include "generated/strings.hpp"

#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <algorithm>
#include <stdexcept>

namespace doppelscreen {
namespace {
constexpr wchar_t window_class[] = L"DoppelScreen.MainWindow";
constexpr UINT tray_message = WM_APP + 1;
constexpr UINT state_changed = WM_APP + 2;
constexpr UINT display_changed = WM_APP + 3;
constexpr int id_show = 200;
constexpr int id_quit = 201;
constexpr int app_icon = 1;
// 論理ピクセル。作ったあとで表示先の DPI に合わせて広げる
constexpr int initial_width = 960;
constexpr int initial_height = 680;

std::wstring_view text(const std::array<std::wstring_view, 2>& value, int language) {
  return value[std::clamp(language, 0, 1)];
}
}  // namespace

MainWindow::MainWindow(HINSTANCE instance) : instance_(instance) {
  wchar_t locale[LOCALE_NAME_MAX_LENGTH]{};
  GetUserDefaultLocaleName(locale, std::size(locale));
  language_ = std::wstring_view(locale).starts_with(L"ja") ? 0 : 1;
  WNDCLASSEXW registration{sizeof(registration)};
  registration.hInstance = instance_;
  registration.lpfnWndProc = window_proc;
  registration.lpszClassName = window_class;
  registration.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  registration.hIcon = LoadIconW(instance_, MAKEINTRESOURCEW(app_icon));
  registration.hIconSm = registration.hIcon;
  RegisterClassExW(&registration);
  window_ = CreateWindowExW(0, window_class, L"DoppelScreen", WS_OVERLAPPEDWINDOW,
                            CW_USEDEFAULT, CW_USEDEFAULT, initial_width, initial_height, nullptr, nullptr,
                            instance_, this);
  const auto dpi = GetDpiForWindow(window_);
  SetWindowPos(window_, nullptr, 0, 0, MulDiv(initial_width, dpi, USER_DEFAULT_SCREEN_DPI),
               MulDiv(initial_height, dpi, USER_DEFAULT_SCREEN_DPI), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  apply_theme();

  controller_ = std::make_unique<SessionController>(viewer_path());
  controller_->set_change_handler([this] { PostMessageW(window_, state_changed, 0, 0); });

  RECT area{};
  GetClientRect(window_, &area);
  flutter_ = std::make_unique<flutter::FlutterViewController>(area.right, area.bottom, flutter::DartProject(L"data"));
  if (!flutter_->engine() || !flutter_->view()) throw std::runtime_error("Flutter engine failed to start");
  const auto content = flutter_->view()->GetNativeWindow();
  SetParent(content, window_);
  MoveWindow(content, 0, 0, area.right, area.bottom, TRUE);
  bridge_ = std::make_unique<HostBridge>(flutter_->engine()->messenger(), *controller_, language_);
  // 最初のフレームが描けてから出す。空の窓が一瞬見えるのを避ける
  flutter_->engine()->SetNextFrameCallback([this] { show(); });
  // コールバックを登録する前に最初のフレームが済んでいることがある
  flutter_->ForceRedraw();

  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = tray_message;
  tray_.hIcon = registration.hIcon;
  wcscpy_s(tray_.szTip, L"DoppelScreen");
  Shell_NotifyIconW(NIM_ADD, &tray_);
  // トークンの残り時間を進めるため、1 秒ごとに状態を送り直す
  SetTimer(window_, 1, 1000, nullptr);
}

MainWindow::~MainWindow() {
  if (controller_) controller_->stop_serving();
  Shell_NotifyIconW(NIM_DELETE, &tray_);
}

int MainWindow::run() {
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return static_cast<int>(message.wParam);
}

LRESULT CALLBACK MainWindow::window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  MainWindow* self = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<MainWindow*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    self->window_ = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  return self ? self->handle_message(message, wparam, lparam)
              : DefWindowProcW(window, message, wparam, lparam);
}

LRESULT MainWindow::handle_message(UINT message, WPARAM wparam, LPARAM lparam) {
  // Flutter が先に見る（IME・DPI の変化・アクセシビリティなど）
  if (flutter_) {
    if (const auto result = flutter_->HandleTopLevelWindowProc(window_, message, wparam, lparam)) {
      return *result;
    }
  }
  switch (message) {
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case id_show: show(); return 0;
        case id_quit: quitting_ = true; DestroyWindow(window_); return 0;
      }
      break;
    case WM_SIZE:
      if (flutter_) {
        RECT area{};
        GetClientRect(window_, &area);
        MoveWindow(flutter_->view()->GetNativeWindow(), 0, 0, area.right, area.bottom, TRUE);
      }
      return 0;
    case WM_ACTIVATE:
      if (flutter_) SetFocus(flutter_->view()->GetNativeWindow());
      return 0;
    case WM_FONTCHANGE:
      if (flutter_) flutter_->engine()->ReloadSystemFonts();
      break;
    case WM_DPICHANGED: {
      const auto* suggested = reinterpret_cast<const RECT*>(lparam);
      SetWindowPos(window_, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                   suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_DWMCOLORIZATIONCOLORCHANGED: apply_theme(); return 0;
    case state_changed:
    case WM_TIMER:
      if (bridge_) bridge_->publish();
      return 0;
    case display_changed: controller_->refresh_displays(); return 0;
    case tray_message:
      if (lparam == WM_LBUTTONUP) show();
      if (lparam == WM_RBUTTONUP) show_tray_menu();
      return 0;
    case WM_DISPLAYCHANGE: PostMessageW(window_, display_changed, 0, 0); return 0;
    case WM_CLOSE:
      if (!quitting_) { ShowWindow(window_, SW_HIDE); return 0; }
      break;
    case WM_DESTROY:
      bridge_.reset();
      flutter_.reset();
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(window_, message, wparam, lparam);
}

void MainWindow::show() {
  ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
  // 隠れている間は Flutter が描き直さない。出した瞬間に古い画面が見えないようにする
  if (flutter_) flutter_->ForceRedraw();
}

void MainWindow::show_tray_menu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  auto menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, id_show, std::wstring(text(l10n::host_menu_showWindow, language_)).c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, id_quit, std::wstring(text(l10n::host_menu_quit, language_)).c_str());
  SetForegroundWindow(window_);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_, nullptr);
  DestroyMenu(menu);
}

// タイトルバーの濃淡を OS の設定に揃える。中身（Flutter）は自分で OS の設定に従う
void MainWindow::apply_theme() {
  DWORD light = 1;
  DWORD size = sizeof(light);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
               L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  const BOOL dark = light == 0;
  DwmSetWindowAttribute(window_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

std::filesystem::path MainWindow::viewer_path() const {
  wchar_t executable[MAX_PATH]{};
  GetModuleFileNameW(nullptr, executable, std::size(executable));
  return std::filesystem::path(executable).parent_path() / L"viewer.html";
}

}  // namespace doppelscreen
