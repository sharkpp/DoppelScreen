#include "capture/display_catalog.hpp"

#include <shellscalingapi.h>
#include <algorithm>

namespace doppelscreen {
namespace {
DisplayId display_id(std::wstring_view device) {
  std::uint32_t hash = 2166136261u;
  for (const auto value : device) {
    hash ^= static_cast<std::uint16_t>(value);
    hash *= 16777619u;
  }
  return hash;
}

std::string utf8(std::wstring_view value) {
  const auto size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                        nullptr, 0, nullptr, nullptr);
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      output.data(), size, nullptr, nullptr);
  return output;
}

BOOL CALLBACK collect(HMONITOR monitor, HDC, LPRECT, LPARAM value) {
  auto& output = *reinterpret_cast<std::vector<DisplayCatalog::Entry>*>(value);
  MONITORINFOEXW monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(monitor, &monitor_info)) return TRUE;

  DISPLAY_DEVICEW display_device{};
  display_device.cb = sizeof(display_device);
  EnumDisplayDevicesW(monitor_info.szDevice, 0, &display_device, 0);

  UINT dpi_x = 96;
  UINT dpi_y = 96;
  GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  const auto width = monitor_info.rcMonitor.right - monitor_info.rcMonitor.left;
  const auto height = monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top;
  const auto name = display_device.DeviceString[0] ? display_device.DeviceString : monitor_info.szDevice;
  output.push_back({DisplayInfo{display_id(monitor_info.szDevice), utf8(name), width, height,
                                static_cast<double>(dpi_x) / 96.0,
                                (monitor_info.dwFlags & MONITORINFOF_PRIMARY) != 0}, monitor});
  return TRUE;
}
}  // namespace

std::vector<DisplayCatalog::Entry> DisplayCatalog::enumerate() {
  std::vector<Entry> result;
  EnumDisplayMonitors(nullptr, nullptr, collect, reinterpret_cast<LPARAM>(&result));
  return result;
}

std::optional<DisplayCatalog::Entry> DisplayCatalog::find(DisplayId id) {
  auto entries = enumerate();
  const auto found = std::find_if(entries.begin(), entries.end(), [id](const auto& value) { return value.info.id == id; });
  return found == entries.end() ? std::nullopt : std::optional(*found);
}

}  // namespace doppelscreen
