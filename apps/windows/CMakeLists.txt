cmake_minimum_required(VERSION 3.28)
project(DoppelScreenWindows VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "The Windows host must be configured with a Windows toolchain")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CONFIGURATION_TYPES "Release" CACHE STRING "" FORCE)

find_package(Boost REQUIRED COMPONENTS system)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)
find_program(NPM_EXECUTABLE NAMES npm.cmd npm REQUIRED)
find_path(QRENCODE_INCLUDE_DIR qrencode.h REQUIRED)
find_library(QRENCODE_LIBRARY NAMES qrencode qrencoded REQUIRED)

set(WEBRTC_ROOT "" CACHE PATH "Extracted shiguredo webrtc-build directory")
if(NOT EXISTS "${WEBRTC_ROOT}/include" OR NOT EXISTS "${WEBRTC_ROOT}/lib/webrtc.lib")
  message(FATAL_ERROR "Set WEBRTC_ROOT to a shiguredo windows_x86_64 archive containing include/ and lib/webrtc.lib")
endif()
file(READ "${WEBRTC_ROOT}/VERSIONS" WEBRTC_VERSIONS)
if(NOT WEBRTC_VERSIONS MATCHES "WEBRTC_BUILD_VERSION=152\\.7977\\.0\\.0")
  message(FATAL_ERROR "DoppelScreen requires shiguredo webrtc-build m152.7977.0.0")
endif()

add_library(doppelscreen_core
  src/core/pairing_service.cpp
  src/core/protocol.cpp
  src/core/video_encoding.cpp
)
target_include_directories(doppelscreen_core PUBLIC src)
target_link_libraries(doppelscreen_core PUBLIC nlohmann_json::nlohmann_json bcrypt)
target_compile_definitions(doppelscreen_core PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)

add_executable(DoppelScreen WIN32
  src/app/main.cpp
  src/app/main_window.cpp
  src/capture/d3d_device.cpp
  src/capture/display_catalog.cpp
  src/capture/screen_capturer.cpp
  src/server/local_server.cpp
  src/server/network_interfaces.cpp
  src/server/tls_identity.cpp
  src/session/session_controller.cpp
  src/video/d3d_video_frame_buffer.cpp
  src/video/media_foundation_h264_encoder.cpp
  src/video/media_foundation_h264_encoder_factory.cpp
  src/video/peer_transport.cpp
  resources/DoppelScreen.rc
)
target_include_directories(DoppelScreen PRIVATE src "${WEBRTC_ROOT}/include" "${QRENCODE_INCLUDE_DIR}")
target_link_directories(DoppelScreen PRIVATE "${WEBRTC_ROOT}/lib")
target_link_libraries(DoppelScreen PRIVATE
  doppelscreen_core Boost::system OpenSSL::SSL OpenSSL::Crypto webrtc
  "${QRENCODE_LIBRARY}"
  d3d11 dxgi dxguid dwmapi mf mfplat mfuuid wmcodecdspuuid ws2_32 iphlpapi shell32 shcore shlwapi windowsapp runtimeobject
  advapi32 avrt crypt32 dbghelp dmoguids msdmo ole32 oleaut32 secur32 strmiids userenv winmm
)
target_compile_definitions(DoppelScreen PRIVATE
  NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE WEBRTC_WIN
  _WIN32_WINNT=0x0A00 WINVER=0x0A00
)

set(VIEWER_HTML "${CMAKE_CURRENT_BINARY_DIR}/viewer.html")
file(GLOB_RECURSE VIEWER_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/../web/src/*"
  "${CMAKE_CURRENT_SOURCE_DIR}/../web/public/*"
)
add_custom_command(
  OUTPUT "${VIEWER_HTML}"
  COMMAND "${NPM_EXECUTABLE}" --prefix "${CMAKE_CURRENT_SOURCE_DIR}/../web" ci --silent
  COMMAND "${NPM_EXECUTABLE}" --prefix "${CMAKE_CURRENT_SOURCE_DIR}/../web" run build
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/../web/dist/index.html" "${VIEWER_HTML}"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/../web/package.json"
    "${CMAKE_CURRENT_SOURCE_DIR}/../web/package-lock.json"
    ${VIEWER_SOURCES}
  VERBATIM
)
add_custom_target(windows_viewer DEPENDS "${VIEWER_HTML}")
add_dependencies(DoppelScreen windows_viewer)
add_custom_command(TARGET DoppelScreen POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${VIEWER_HTML}" "$<TARGET_FILE_DIR:DoppelScreen>/viewer.html"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/../../THIRD-PARTY-NOTICES.md"
          "$<TARGET_FILE_DIR:DoppelScreen>/THIRD-PARTY-NOTICES.md"
)

include(CTest)
if(BUILD_TESTING)
  find_package(Catch2 3 CONFIG REQUIRED)
  add_executable(doppelscreen_windows_tests
    tests/pairing_service_tests.cpp
    tests/protocol_tests.cpp
    tests/video_encoding_tests.cpp
  )
  target_link_libraries(doppelscreen_windows_tests PRIVATE doppelscreen_core Catch2::Catch2WithMain)
  include(Catch)
  catch_discover_tests(doppelscreen_windows_tests)
endif()
