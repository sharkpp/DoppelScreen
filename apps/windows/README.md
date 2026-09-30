# Windows ホスト

Windows 11 x64 向けのネイティブホストです。Windows Graphics Capture から受け取った
D3D11 テクスチャを Media Foundation のハードウェア H.264 エンコーダへ渡し、
libwebrtc で LAN 内のブラウザへ配信します。

## 必要なもの

- Windows 11 x64
- Visual Studio 2022（「C++ によるデスクトップ開発」と Windows 11 SDK）
- CMake 3.28 以上、Node.js 20 以上
- Flutter SDK 3.47 以上（ウィンドウの中身。`flutter` に PATH を通す）
- vcpkg
- shiguredo webrtc-build `m152.7977.0.0` の Windows x86_64 バイナリ

libwebrtc は次の固定バージョンを使います。CMake は `VERSIONS` も検査するため、
別バージョンを誤ってリンクしません。

```powershell
$archive = "$env:TEMP\doppelscreen-webrtc.zip"
$webrtc = "$env:LOCALAPPDATA\DoppelScreen\webrtc-m152.7977.0.0"
curl.exe -L "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/m152.7977.0.0/webrtc.windows_x86_64.zip" -o $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLower() -ne "fbc4afe2f9e0a8a42ca8afb94f0ba37511c0dba7728be012edee86ee848435a4") { throw "libwebrtc archive checksum mismatch" }
New-Item -ItemType Directory -Force $webrtc | Out-Null
Expand-Archive -Force $archive $webrtc
$env:WEBRTC_ROOT = "$webrtc\webrtc"
```

`WEBRTC_ROOT` の直下には `include`、`lib/webrtc.lib`、`VERSIONS` が必要です。

## ビルドとテスト

Visual Studio 2022 の Developer PowerShell で、リポジトリのルートから実行します。

```powershell
$env:VCPKG_ROOT = "C:\src\vcpkg"
make windows-build   # 最初に windows-host-ui（Flutter の CMake 設定の生成）も走る
make windows-test
make windows-run
```

Make を使わない場合は次のコマンドでも同じです。

```powershell
Set-Location apps/host_ui
flutter build windows --config-only --release
Set-Location ../windows
cmake --preset windows-x64
cmake --build --preset windows-x64-release
ctest --preset windows-x64-release
.\build\Release\DoppelScreen.exe
```

libwebrtc の配布バイナリと CRT を揃えるため、Windows ホストは Release +
`x64-windows-static` でビルドします。Web ビューアはビルド時に単一の `viewer.html` へまとめられ、
実行ファイルと同じディレクトリへコピーされます。ウィンドウの中身は macOS と共通の
Flutter のホスト UI（[apps/host_ui](../host_ui)）で、`flutter_windows.dll` と `data/` が
実行ファイルの隣に並びます。

## 操作

「配信を開始」を押すと、ディスプレイごとに HTTP / HTTPS の URL が表示されます。
URL は選択してコピーでき、各行のボタンで QR の表示とコピーもできます。同じ型名のディスプレイは
DISPLAY 番号で区別できます。ブラウザから接続要求が来たら、対象ディスプレイの行で承認すると
配信が始まります。ウィンドウを閉じても通知領域に常駐し、通知領域メニューの「終了」で停止します。

自己署名証明書は `%LOCALAPPDATA%\DoppelScreen\tls` に保存されます。秘密鍵は Windows DPAPI で
現在のユーザーに結び付けて暗号化されます。LAN アドレスが増えた場合だけ証明書を更新します。
