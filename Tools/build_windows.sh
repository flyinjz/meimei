#!/usr/bin/env bash
# Builds i2s for Windows: the shared Swift core (release), then the Qt app,
# into .build-windows/. Run from the repository root in an MSYS2 UCRT64 shell:
#   bash Tools/build_windows.sh        build
#   bash Tools/build_windows.sh run    build, then start the app
#   bash Tools/build_windows.sh test   build, then run the headless self-test
# Needs: Swift for Windows (per user), Visual Studio Build Tools (MSVC +
# Windows SDK), MSYS2 UCRT64 with Qt 6, FFmpeg, miniaudio, CMake, Ninja.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -W)"

SWIFT_ROOT="${SWIFT_ROOT:-$LOCALAPPDATA/Programs/Swift}"
SWIFT_VERSION="${SWIFT_VERSION:-6.4.2}"
VCVARS="${VCVARS:-C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat}"

# 1. The core, with MSVC and the Swift toolchain (in cmd, where vcvars works).
trap 'rm -f .build-core-env.cmd' EXIT
cat > .build-core-env.cmd <<EOF
@echo off
call "$VCVARS" >nul
set "SDKROOT=$SWIFT_ROOT\\Platforms\\$SWIFT_VERSION\\Windows.platform\\Developer\\SDKs\\Windows.sdk\\"
set "PATH=$SWIFT_ROOT\\Toolchains\\$SWIFT_VERSION+Asserts\\usr\\bin;$SWIFT_ROOT\\Runtimes\\$SWIFT_VERSION\\usr\\bin;C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer;%PATH%"
cd /d "$ROOT"
swift build -c release --scratch-path .build-core --product I2SCore
EOF
cmd //c "$(pwd -W | sed 's#/#\\#g')\\.build-core-env.cmd"

# 2. The app.
cmake -S Windows -B .build-windows -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DI2S_SWIFT_RUNTIME="$SWIFT_ROOT/Runtimes/$SWIFT_VERSION/usr/bin" >/dev/null
cmake --build .build-windows

case "${1:-}" in
  run)  ./.build-windows/i2s.exe & ;;
  test) out="$(mktemp -d)"
        ./.build-windows/i2s.exe --self-test "$out/self-test.txt" --support-dir "$out/support" || true
        cat "$out/self-test.txt" ;;
esac
