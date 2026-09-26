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
  window_ = CreateWindowExW(0, window_class, L"DoppelScreen", WS_OVERLAPPEDWINDOW | WS_VSCROLL,
                            CW_USEDEFAULT, CW_USEDEFAULT, 960, 680, nullptr, nullptr,
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
      for (const auto& row : rows_) {
        if (reinterpret_cast<HWND>(lparam) == row.approve) { controller_->approve(row.id); return 0; }
        if (reinterpret_cast<HWND>(lparam) == row.reject) { controller_->reject(row.id); return 0; }
        if (reinterpret_cast<HWND>(lparam) == row.disconnect) { controller_->disconnect(row.id); return 0; }
        for (const auto& url : row.urls) {
          if (reinterpret_cast<HWND>(lparam) == url.copy) { copy_url(url.url); return 0; }
          if (reinterpret_cast<HWND>(lparam) == url.qr) {
            expanded_url_ = expanded_url_ == url.url ? "" : url.url;
            layout();
            if (!expanded_url_.empty()) {
              RECT area{};
              GetClientRect(window_, &area);
              int bottom = 112;
              bool found = false;
              for (const auto& display : rows_) {
                bottom += 76;
                for (const auto& endpoint : display.urls) {
                  bottom += 38;
                  if (endpoint.url == expanded_url_) {
                    bottom += 208;
                    scroll_offset_ = std::max(scroll_offset_, bottom - static_cast<int>(area.bottom) + 12);
                    layout();
                    found = true;
                    break;
                  }
                }
                if (found) break;
                bottom += 14;
              }
            }
            InvalidateRect(window_, nullptr, TRUE);
            return 0;
          }
        }
      }
      switch (LOWORD(wparam)) {
        case id_start_stop:
          if (snapshot_.server_state == SessionController::ServerState::running) controller_->stop_serving();
          else controller_->start_serving();
          return 0;
        case id_regenerate: controller_->regenerate_token(); return 0;
        case 200: ShowWindow(window_, SW_SHOW); SetForegroundWindow(window_); return 0;
        case 201: quitting_ = true; DestroyWindow(window_); return 0;
      }
      break;
    case WM_SIZE: layout(); return 0;
    case WM_VSCROLL: {
      SCROLLINFO info{sizeof(info), SIF_ALL};
      GetScrollInfo(window_, SB_VERT, &info);
      int next = scroll_offset_;
      switch (LOWORD(wparam)) {
        case SB_LINEUP: next -= 40; break;
        case SB_LINEDOWN: next += 40; break;
        case SB_PAGEUP: next -= static_cast<int>(info.nPage); break;
        case SB_PAGEDOWN: next += static_cast<int>(info.nPage); break;
        case SB_THUMBTRACK: next = info.nTrackPos; break;
      }
      scroll_offset_ = std::clamp(next, 0, std::max(0, content_height_ - static_cast<int>(info.nPage)));
      layout();
      InvalidateRect(window_, nullptr, TRUE);
      return 0;
    }
    case WM_MOUSEWHEEL:
      SendMessageW(window_, WM_VSCROLL, MAKEWPARAM(GET_WHEEL_DELTA_WPARAM(wparam) > 0 ? SB_LINEUP : SB_LINEDOWN, 0), 0);
      return 0;
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
                           0, 0, 120, 32, window_,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), instance_, nullptr);
  };
  start_stop_ = button(id_start_stop, text(l10n::host_control_start, language_));
  regenerate_ = button(id_regenerate, text(l10n::host_pairing_regenerate, language_));
  status_ = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE,
                           0, 0, 0, 0, window_, nullptr, instance_, nullptr);
  token_ = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE,
                          0, 0, 0, 0, window_, nullptr, instance_, nullptr);
}

void MainWindow::refresh() {
  snapshot_ = controller_->snapshot();
  const auto running = snapshot_.server_state == SessionController::ServerState::running;
  SetWindowTextW(start_stop_, std::wstring(text(running ? l10n::host_control_stop : l10n::host_control_start, language_)).c_str());
  EnableWindow(start_stop_, !snapshot_.streams.empty() &&
      snapshot_.server_state != SessionController::ServerState::starting);
  EnableWindow(regenerate_, running);
  std::wstring status;
  if (snapshot_.server_state == SessionController::ServerState::idle) status = text(l10n::host_menu_stopped, language_);
  else if (snapshot_.server_state == SessionController::ServerState::starting) status = text(l10n::host_menu_starting, language_);
  else if (snapshot_.server_state == SessionController::ServerState::failed) status = widen(snapshot_.server_error);
  else {
    const auto pending = std::ranges::count_if(snapshot_.streams, [](const auto& stream) {
      return stream.state == SessionController::StreamState::awaiting_approval;
    });
    if (pending) status = interpolate(text(l10n::host_status_requests, language_), L"count", std::to_wstring(pending));
    else {
      const auto active = std::ranges::count_if(snapshot_.streams, [](const auto& stream) {
        return stream.state == SessionController::StreamState::streaming;
      });
      status = interpolate(text(l10n::host_status_streaming, language_), L"active", std::to_wstring(active));
      status = interpolate(status, L"total", std::to_wstring(snapshot_.streams.size()));
    }
  }
  SetWindowTextW(status_, status.c_str());
  auto token = interpolate(text(l10n::host_pairing_token, language_), L"token", widen(snapshot_.pairing.token));
  if (running) {
    const auto seconds = snapshot_.pairing.remaining.count() / 1000;
    token += L"   ";
    token += seconds > 0 ? interpolate(text(l10n::host_pairing_expires, language_),
                                       L"seconds", std::to_wstring(seconds))
                         : std::wstring(text(l10n::host_pairing_expired, language_));
    if (snapshot_.pairing.regenerated_after_failures) {
      token += L"   ";
      token += text(l10n::host_pairing_rejected, language_);
    }
  }
  SetWindowTextW(token_, running ? token.c_str() : L"");
  rebuild_rows();
  for (std::size_t i = 0; i < rows_.size(); ++i) {
    const auto& stream = snapshot_.streams[i];
    auto& row = rows_[i];
    const auto awaiting = stream.state == SessionController::StreamState::awaiting_approval;
    const auto active = stream.state == SessionController::StreamState::connecting ||
                        stream.state == SessionController::StreamState::streaming;
    ShowWindow(row.approve, awaiting ? SW_SHOW : SW_HIDE);
    ShowWindow(row.reject, awaiting ? SW_SHOW : SW_HIDE);
    ShowWindow(row.disconnect, active ? SW_SHOW : SW_HIDE);
    std::wstring detail;
    switch (stream.state) {
      case SessionController::StreamState::idle: detail = text(l10n::host_connection_idle, language_); break;
      case SessionController::StreamState::awaiting_approval:
        detail = interpolate(text(l10n::host_connection_request, language_), L"address", widen(stream.remote_address)); break;
      case SessionController::StreamState::connecting:
        detail = interpolate(text(l10n::host_connection_connecting, language_), L"address", widen(stream.remote_address)); break;
      case SessionController::StreamState::streaming:
        detail = interpolate(text(l10n::host_connection_streaming, language_), L"address", widen(stream.remote_address)); break;
      case SessionController::StreamState::failed: detail = widen(stream.error); break;
    }
    SetWindowTextW(row.status, detail.c_str());
  }
  layout();
  InvalidateRect(window_, nullptr, TRUE);
}

void MainWindow::rebuild_rows() {
  std::vector<DisplayInfo> displays;
  for (const auto& stream : snapshot_.streams) displays.push_back(stream.display);
  const auto same_endpoints = displayed_endpoints_.size() == snapshot_.endpoints.size() &&
      std::equal(displayed_endpoints_.begin(), displayed_endpoints_.end(), snapshot_.endpoints.begin(),
          [](const auto& a, const auto& b) { return a.display_id == b.display_id &&
              a.interface_name == b.interface_name && a.url == b.url && a.secure_url == b.secure_url; });
  const auto same_displays = displayed_displays_.size() == displays.size() &&
      std::equal(displayed_displays_.begin(), displayed_displays_.end(), displays.begin(),
          [](const auto& a, const auto& b) { return a.id == b.id && a.name == b.name &&
              a.width == b.width && a.height == b.height; });
  if (same_endpoints && same_displays) return;
  for (auto& row : rows_) {
    for (auto& url : row.urls) {
      DestroyWindow(url.interface_label); DestroyWindow(url.edit);
      DestroyWindow(url.copy); DestroyWindow(url.qr);
    }
    DestroyWindow(row.heading); DestroyWindow(row.status);
    DestroyWindow(row.approve); DestroyWindow(row.reject); DestroyWindow(row.disconnect);
  }
  rows_.clear();
  displayed_endpoints_ = snapshot_.endpoints;
  displayed_displays_ = std::move(displays);
  expanded_url_.clear();
  const auto label = [this](std::wstring value) {
    return CreateWindowExW(0, L"STATIC", value.c_str(), WS_CHILD | WS_VISIBLE,
                           0, 0, 0, 0, window_, nullptr, instance_, nullptr);
  };
  const auto button = [this](std::wstring_view value) {
    return CreateWindowExW(0, L"BUTTON", std::wstring(value).c_str(),
                           WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                           window_, nullptr, instance_, nullptr);
  };
  for (const auto& stream : snapshot_.streams) {
    DisplayRow row;
    row.id = stream.display.id;
    row.heading = label(std::format(L"{}  ({} × {})", widen(stream.display.name),
                                    stream.display.width, stream.display.height));
    row.status = label(L"");
    row.approve = button(text(l10n::host_connection_approve, language_));
    row.reject = button(text(l10n::host_connection_reject, language_));
    row.disconnect = button(text(l10n::host_connection_disconnect, language_));
    for (const auto& endpoint : snapshot_.endpoints) {
      if (endpoint.display_id != row.id) continue;
      const auto add_url = [&](std::string url, std::wstring interface_name) {
        UrlRow item;
        item.url = std::move(url);
        item.interface_label = label(std::move(interface_name));
        item.edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", widen(item.url).c_str(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL | ES_READONLY,
            0, 0, 0, 0, window_, nullptr, instance_, nullptr);
        item.copy = button(text(l10n::host_connection_copyUrl, language_));
        item.qr = button(L"QR");
        row.urls.push_back(std::move(item));
      };
      add_url(endpoint.url, endpoint.interface_name);
      if (!endpoint.secure_url.empty()) add_url(endpoint.secure_url, L"HTTPS");
    }
    rows_.push_back(std::move(row));
  }
}

void MainWindow::layout() {
  if (!window_) return;
  RECT area{};
  GetClientRect(window_, &area);
  const int width = area.right;
  if (snapshot_.server_state != SessionController::ServerState::running) {
    MoveWindow(status_, 24, 22, std::max(0, width - 210), 28, TRUE);
    MoveWindow(start_stop_, width - 170, 18, 146, 34, TRUE);
    ShowWindow(token_, SW_HIDE);
    ShowWindow(regenerate_, SW_HIDE);
    content_height_ = 0;
    scroll_offset_ = 0;
    SetScrollRange(window_, SB_VERT, 0, 0, TRUE);
    return;
  }
  ShowWindow(token_, SW_SHOW);
  ShowWindow(regenerate_, SW_SHOW);
  int total = 112;
  for (const auto& row : rows_) {
    total += 76;
    for (const auto& url : row.urls) total += 38 + (expanded_url_ == url.url ? 208 : 0);
    total += 14;
  }
  content_height_ = total;
  SCROLLINFO info{sizeof(info), SIF_RANGE | SIF_PAGE | SIF_POS};
  info.nMin = 0; info.nMax = std::max(total, static_cast<int>(area.bottom)) - 1;
  info.nPage = area.bottom;
  scroll_offset_ = std::clamp(scroll_offset_, 0, std::max(0, total - static_cast<int>(area.bottom)));
  info.nPos = scroll_offset_;
  SetScrollInfo(window_, SB_VERT, &info, TRUE);
  MoveWindow(status_, 24, 22 - scroll_offset_, std::max(0, width - 210), 28, TRUE);
  MoveWindow(start_stop_, width - 170, 18 - scroll_offset_, 146, 34, TRUE);
  MoveWindow(token_, 24, 70 - scroll_offset_, std::max(0, width - 220), 26, TRUE);
  MoveWindow(regenerate_, width - 170, 66 - scroll_offset_, 146, 30, TRUE);
  int y = 112 - scroll_offset_;
  for (const auto& row : rows_) {
    MoveWindow(row.heading, 24, y, std::max(0, width - 48), 25, TRUE);
    MoveWindow(row.status, 24, y + 30, std::max(0, width - 320), 28, TRUE);
    MoveWindow(row.approve, width - 290, y + 26, 85, 30, TRUE);
    MoveWindow(row.reject, width - 195, y + 26, 85, 30, TRUE);
    MoveWindow(row.disconnect, width - 130, y + 26, 105, 30, TRUE);
    y += 76;
    for (const auto& url : row.urls) {
      MoveWindow(url.interface_label, 32, y + 6, 100, 25, TRUE);
      MoveWindow(url.edit, 132, y, std::max(100, width - 337), 30, TRUE);
      MoveWindow(url.qr, width - 195, y, 60, 30, TRUE);
      MoveWindow(url.copy, width - 125, y, 100, 30, TRUE);
      y += 38 + (expanded_url_ == url.url ? 208 : 0);
    }
    y += 14;
  }
}

void MainWindow::paint(HDC dc) {
  SetBkMode(dc, TRANSPARENT);
  RECT area{};
  GetClientRect(window_, &area);
  if (snapshot_.server_state != SessionController::ServerState::running) {
    const auto message = snapshot_.streams.empty() ? text(l10n::host_control_noDisplay, language_)
                                                    : text(l10n::host_control_idleHint, language_);
    RECT hint{80, area.bottom / 2 - 50, area.right - 80, area.bottom / 2 + 70};
    DrawTextW(dc, message.data(), static_cast<int>(message.size()), &hint,
              DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_NOPREFIX);
    return;
  }
  int y = 112 - scroll_offset_;
  for (const auto& row : rows_) {
    y += 76;
    for (const auto& url : row.urls) {
      if (expanded_url_ == url.url) {
        draw_qr(dc, url.url, {132, y + 38, 312, y + 218});
        auto hint = text(l10n::host_connection_scanHint, language_);
        RECT hint_area{326, y + 46, area.right - 24, y + 110};
        DrawTextW(dc, hint.data(), static_cast<int>(hint.size()), &hint_area, DT_WORDBREAK | DT_NOPREFIX);
      }
      y += 38 + (expanded_url_ == url.url ? 208 : 0);
    }
    y += 14;
  }
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

void MainWindow::copy_url(std::string_view url) {
  if (!OpenClipboard(window_)) return;
  const auto value = widen(url);
  const auto bytes = (value.size() + 1) * sizeof(wchar_t);
  auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory) {
    auto target = GlobalLock(memory);
    if (target) {
      memcpy(target, value.c_str(), bytes);
      GlobalUnlock(memory);
      EmptyClipboard();
      if (!SetClipboardData(CF_UNICODETEXT, memory)) GlobalFree(memory);
    } else GlobalFree(memory);
  }
  CloseClipboard();
}

std::filesystem::path MainWindow::viewer_path() const {
  wchar_t executable[MAX_PATH]{};
  GetModuleFileNameW(nullptr, executable, std::size(executable));
  return std::filesystem::path(executable).parent_path() / L"viewer.html";
}

}  // namespace doppelscreen
