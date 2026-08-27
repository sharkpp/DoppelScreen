#include "app/main_window.hpp"

#include "generated/strings.hpp"

#include <shellapi.h>
#include <shlwapi.h>
#include <algorithm>
#include <cstring>
#include <format>
#include <qrencode.h>

namespace doppelscreen {
namespace {
constexpr wchar_t window_class[] = L"DoppelScreen.MainWindow";
constexpr UINT tray_message = WM_APP + 1;
constexpr UINT state_changed = WM_APP + 2;
constexpr UINT display_changed = WM_APP + 3;
constexpr int id_start_stop = 100;
constexpr int id_regenerate = 101;
constexpr int id_approve = 102;
constexpr int id_reject = 103;
constexpr int id_disconnect = 104;
constexpr int id_copy_url = 105;
constexpr int app_icon = 1;

std::wstring widen(std::string_view value) {
  if (value.empty()) return {};
  const auto size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring output(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), output.data(), size);
  return output;
}

std::wstring_view text(const std::array<std::wstring_view, 2>& value, int language) {
  return value[std::clamp(language, 0, 1)];
}

std::wstring interpolate(std::wstring_view pattern, std::wstring_view key, std::wstring_view value) {
  std::wstring output(pattern);
  const auto marker = L"{" + std::wstring(key) + L"}";
  if (const auto position = output.find(marker); position != std::wstring::npos) {
    output.replace(position, marker.size(), value);
  }
  return output;
}

void draw_qr(HDC dc, std::string_view value, RECT area) {
  auto* code = QRcode_encodeString8bit(std::string(value).c_str(), 0, QR_ECLEVEL_M);
  if (!code) return;
  const auto modules = code->width + 8;
  const auto scale = std::max(1L, std::min(area.right - area.left, area.bottom - area.top) / modules);
  const auto size = modules * scale;
  RECT background{area.left, area.top, area.left + size, area.top + size};
  FillRect(dc, &background, reinterpret_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
  auto brush = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  for (int y = 0; y < code->width; ++y) {
    for (int x = 0; x < code->width; ++x) {
      if ((code->data[y * code->width + x] & 1) == 0) continue;
      RECT module{area.left + (x + 4) * scale, area.top + (y + 4) * scale,
                  area.left + (x + 5) * scale, area.top + (y + 5) * scale};
      FillRect(dc, &module, brush);
    }
  }
  QRcode_free(code);
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
  registration.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassExW(&registration);
  window_ = CreateWindowExW(0, window_class, L"DoppelScreen", WS_OVERLAPPEDWINDOW,
                            CW_USEDEFAULT, CW_USEDEFAULT, 760, 640, nullptr, nullptr,
                            instance_, this);
  create_controls();
  controller_ = std::make_unique<SessionController>(viewer_path());
  controller_->set_change_handler([this] { PostMessageW(window_, state_changed, 0, 0); });
  refresh();

  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = tray_message;
  tray_.hIcon = registration.hIcon;
  wcscpy_s(tray_.szTip, L"DoppelScreen");
  Shell_NotifyIconW(NIM_ADD, &tray_);
  SetTimer(window_, 1, 1000, nullptr);
  ShowWindow(window_, SW_SHOW);
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
  switch (message) {
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case id_start_stop:
          if (snapshot_.server_state == SessionController::ServerState::running) controller_->stop_serving();
          else controller_->start_serving();
          return 0;
        case id_regenerate: controller_->regenerate_token(); return 0;
        case id_copy_url: copy_primary_url(); return 0;
        case id_approve:
        case id_reject:
        case id_disconnect: {
          const auto found = std::find_if(snapshot_.streams.begin(), snapshot_.streams.end(),
              [command = LOWORD(wparam)](const auto& value) {
                if (command != id_disconnect) {
                  return value.state == SessionController::StreamState::awaiting_approval;
                }
                return value.state == SessionController::StreamState::connecting ||
                       value.state == SessionController::StreamState::streaming ||
                       value.state == SessionController::StreamState::failed;
              });
          if (found != snapshot_.streams.end()) {
            if (LOWORD(wparam) == id_approve) controller_->approve(found->display.id);
            if (LOWORD(wparam) == id_reject) controller_->reject(found->display.id);
            if (LOWORD(wparam) == id_disconnect) controller_->disconnect(found->display.id);
          }
          return 0;
        }
        case 200: ShowWindow(window_, SW_SHOW); SetForegroundWindow(window_); return 0;
        case 201: quitting_ = true; DestroyWindow(window_); return 0;
      }
      break;
    case WM_SIZE: layout(); return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      auto dc = BeginPaint(window_, &paint);
      this->paint(dc);
      EndPaint(window_, &paint);
      return 0;
    }
    case state_changed: refresh(); return 0;
    case WM_TIMER: refresh(); return 0;
    case display_changed: controller_->refresh_displays(); return 0;
    case tray_message:
      if (lparam == WM_LBUTTONUP) { ShowWindow(window_, SW_SHOW); SetForegroundWindow(window_); }
      if (lparam == WM_RBUTTONUP) show_tray_menu();
      return 0;
    case WM_DISPLAYCHANGE: PostMessageW(window_, display_changed, 0, 0); return 0;
    case WM_CLOSE:
      if (!quitting_) { ShowWindow(window_, SW_HIDE); return 0; }
      break;
    case WM_DESTROY: PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(window_, message, wparam, lparam);
}

void MainWindow::create_controls() {
  const auto button = [this](int id, std::wstring_view label) {
    return CreateWindowExW(0, L"BUTTON", std::wstring(label).c_str(), WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                           0, 0, 120, 32, window_, reinterpret_cast<HMENU>(id), instance_, nullptr);
  };
  start_stop_ = button(id_start_stop, text(l10n::host_control_start, language_));
  regenerate_ = button(id_regenerate, text(l10n::host_pairing_regenerate, language_));
  copy_url_ = button(id_copy_url, text(l10n::host_connection_copyUrl, language_));
  approve_ = button(id_approve, text(l10n::host_connection_approve, language_));
  reject_ = button(id_reject, text(l10n::host_connection_reject, language_));
  disconnect_ = button(id_disconnect, text(l10n::host_connection_disconnect, language_));
}

void MainWindow::refresh() {
  snapshot_ = controller_->snapshot();
  const auto running = snapshot_.server_state == SessionController::ServerState::running;
  SetWindowTextW(start_stop_, std::wstring(text(running ? l10n::host_control_stop : l10n::host_control_start, language_)).c_str());
  const auto awaiting = std::ranges::any_of(snapshot_.streams, [](const auto& value) { return value.state == SessionController::StreamState::awaiting_approval; });
  const auto active = std::ranges::any_of(snapshot_.streams, [](const auto& value) {
    return value.state == SessionController::StreamState::connecting ||
           value.state == SessionController::StreamState::streaming ||
           value.state == SessionController::StreamState::failed;
  });
  ShowWindow(approve_, awaiting ? SW_SHOW : SW_HIDE);
  ShowWindow(reject_, awaiting ? SW_SHOW : SW_HIDE);
  ShowWindow(disconnect_, active ? SW_SHOW : SW_HIDE);
  EnableWindow(regenerate_, running);
  EnableWindow(copy_url_, !snapshot_.endpoints.empty());
  InvalidateRect(window_, nullptr, TRUE);
}

void MainWindow::layout() {
  RECT area{};
  GetClientRect(window_, &area);
  MoveWindow(start_stop_, 24, 20, 140, 34, TRUE);
  MoveWindow(regenerate_, 174, 20, 140, 34, TRUE);
  MoveWindow(copy_url_, 324, 20, 140, 34, TRUE);
  MoveWindow(approve_, 24, area.bottom - 54, 120, 34, TRUE);
  MoveWindow(reject_, 154, area.bottom - 54, 120, 34, TRUE);
  MoveWindow(disconnect_, 24, area.bottom - 54, 120, 34, TRUE);
}

void MainWindow::paint(HDC dc) {
  SetBkMode(dc, TRANSPARENT);
  RECT area{};
  GetClientRect(window_, &area);
  RECT content{24, 78, area.right - 24, area.bottom - 72};
  std::wstring output;
  if (snapshot_.server_state == SessionController::ServerState::idle) {
    output = text(l10n::host_control_idleHint, language_);
  } else if (snapshot_.server_state == SessionController::ServerState::starting) {
    output = text(l10n::host_menu_starting, language_);
  } else if (snapshot_.server_state == SessionController::ServerState::failed) {
    output = text(l10n::host_menu_failed, language_);
    output += L"\n" + widen(snapshot_.server_error);
  } else {
    output = interpolate(text(l10n::host_pairing_token, language_), L"token", widen(snapshot_.pairing.token)) + L"\n\n";
    auto y = content.top + 44;
    for (const auto& stream : snapshot_.streams) {
      std::wstring block = std::format(L"{}  ({} × {})\n", widen(stream.display.name), stream.display.width, stream.display.height);
      const SessionController::Endpoint* primary_endpoint = nullptr;
      for (const auto& endpoint : snapshot_.endpoints) {
        if (endpoint.display_id == stream.display.id) {
          if (!primary_endpoint) primary_endpoint = &endpoint;
          block += L"  " + widen(endpoint.url) + L"\n";
          if (!endpoint.secure_url.empty()) block += L"  " + widen(endpoint.secure_url) + L"\n";
        }
      }
      if (stream.state == SessionController::StreamState::awaiting_approval) {
        block += L"  " + interpolate(text(l10n::host_connection_request, language_), L"address", widen(stream.remote_address)) + L"\n";
      } else if (stream.state == SessionController::StreamState::connecting) {
        block += L"  " + interpolate(text(l10n::host_connection_connecting, language_), L"address", widen(stream.remote_address)) + L"\n";
      } else if (stream.state == SessionController::StreamState::streaming) {
        block += L"  " + interpolate(text(l10n::host_connection_streaming, language_), L"address", widen(stream.remote_address)) + L"\n";
      } else if (stream.state == SessionController::StreamState::failed) {
        block += L"  " + widen(stream.error) + L"\n";
      }
      RECT block_area{content.left, y, content.right - 330, y + 150};
      DrawTextW(dc, block.c_str(), static_cast<int>(block.size()), &block_area,
                DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX);
      if (primary_endpoint) {
        draw_qr(dc, primary_endpoint->url,
                {content.right - 310, y, content.right - 160, y + 150});
        if (!primary_endpoint->secure_url.empty()) {
          draw_qr(dc, primary_endpoint->secure_url,
                  {content.right - 150, y, content.right, y + 150});
        }
      }
      y += 170;
    }
    RECT token_area{content.left, content.top, content.right, content.top + 36};
    DrawTextW(dc, output.c_str(), static_cast<int>(output.size()), &token_area, DT_LEFT | DT_TOP | DT_NOPREFIX);
    return;
  }
  DrawTextW(dc, output.c_str(), static_cast<int>(output.size()), &content, DT_LEFT | DT_TOP | DT_WORDBREAK);
}

void MainWindow::show_tray_menu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  auto menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 200, std::wstring(text(l10n::host_menu_showWindow, language_)).c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 201, std::wstring(text(l10n::host_menu_quit, language_)).c_str());
  SetForegroundWindow(window_);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_, nullptr);
  DestroyMenu(menu);
}

void MainWindow::copy_primary_url() {
  if (snapshot_.endpoints.empty() || !OpenClipboard(window_)) return;
  EmptyClipboard();
  const auto value = widen(snapshot_.endpoints.front().url);
  const auto bytes = (value.size() + 1) * sizeof(wchar_t);
  auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory) {
    auto target = GlobalLock(memory);
    memcpy(target, value.c_str(), bytes);
    GlobalUnlock(memory);
    SetClipboardData(CF_UNICODETEXT, memory);
  }
  CloseClipboard();
}

std::filesystem::path MainWindow::viewer_path() const {
  wchar_t executable[MAX_PATH]{};
  GetModuleFileNameW(nullptr, executable, std::size(executable));
  return std::filesystem::path(executable).parent_path() / L"viewer.html";
}

}  // namespace doppelscreen
