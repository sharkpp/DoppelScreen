#include "app/main_window.hpp"

#include <windows.h>
#include <winrt/base.h>
#include <exception>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  HANDLE single_instance = CreateMutexW(nullptr, TRUE, L"Local\\DoppelScreen.Host");
  if (!single_instance) return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (const auto existing = FindWindowW(L"DoppelScreen.MainWindow", nullptr)) {
      ShowWindow(existing, SW_SHOW);
      SetForegroundWindow(existing);
    }
    CloseHandle(single_instance);
    return 0;
  }
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  try {
    doppelscreen::MainWindow window(instance);
    const auto result = window.run();
    CloseHandle(single_instance);
    return result;
  } catch (const std::exception& error) {
    MessageBoxA(nullptr, error.what(), "DoppelScreen", MB_OK | MB_ICONERROR);
    CloseHandle(single_instance);
    return 1;
  }
}
