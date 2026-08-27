#include "app/main_window.hpp"

#include <windows.h>
#include <winrt/base.h>
#include <exception>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  try {
    doppelscreen::MainWindow window(instance);
    return window.run();
  } catch (const std::exception& error) {
    MessageBoxA(nullptr, error.what(), "DoppelScreen", MB_OK | MB_ICONERROR);
    return 1;
  }
}
