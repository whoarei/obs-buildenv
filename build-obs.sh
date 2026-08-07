#!/bin/sh
# obs-builder:debian11-arm64 容器入口：构建挂载进来的 OBS 源码并拷贝产物到 /output
#
# 约定（可用环境变量覆盖）：
#   OBS_SRC_DIR   OBS 源码目录（bind mount 注入）   默认 /src/obs-studio
#   BUILD_DIR     构建目录（建议挂 named volume）   默认 /build/obs-studio
#   OUTPUT_DIR    产物输出目录（bind mount 到宿主机 obs-binary/） 默认 /output
#   EXTRA_CMAKE_FLAGS  追加给首次 cmake 配置的额外 -D 参数
#   OUTPUT_UID / OUTPUT_GID  若设置，产物 chown 到该属主
#
# 行为：
#   1. 在 $OBS_SRC_DIR 查找 OBS 源码；
#   2. cmake 配置（首次）+ ninja 编译（首次用 -k 0 收集全部错误；增量走 ccache）+ CPack 打包；
#   3. deb / ddeb / SHA-256 清单拷贝到 $OUTPUT_DIR。
set -e

OBS_SRC_DIR=${OBS_SRC_DIR:-/src/obs-studio}
BUILD_DIR=${BUILD_DIR:-/build/obs-studio}
OUTPUT_DIR=${OUTPUT_DIR:-/output}
NPROC=$(nproc)

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$OBS_SRC_DIR/CMakeLists.txt" ] \
  || die "OBS 源码未找到：$OBS_SRC_DIR（把 OBS checkout bind mount 到 /src/obs-studio，或用 OBS_SRC_DIR 覆盖）"

# bind mount 源码属主与容器 root 不同，git describe（buildnumber/version）需要豁免
git config --global --add safe.directory "$OBS_SRC_DIR" 2>/dev/null || true

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  FRESH=1
  echo "== 首次配置：$OBS_SRC_DIR -> $BUILD_DIR =="
  # 基线（上游默认）：桌面 OpenGL 渲染后端，不定义 OBS_USE_GLES；
  # OBS_DISABLED_PLUGINS / CPack 元数据按交付配置执行。
  cmake -S "$OBS_SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr/local/ans \
    -DCMAKE_PREFIX_PATH="/usr/local/ans" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DOBS_BUILD_NUMBER=1 \
    -DENABLE_WAYLAND=OFF \
    -DENABLE_BROWSER=OFF -DENABLE_WEBSOCKET=OFF -DENABLE_SCRIPTING=OFF \
    -DENABLE_NEW_MPEGTS_OUTPUT=OFF \
    -DENABLE_RELOCATABLE=ON \
    -DOBS_DISABLED_PLUGINS='aja;aja-output-ui;decklink;decklink-captions;decklink-output-ui;linux-jack;linux-pipewire;nv-filters;mac-virtualcam;obs-libfdk;obs-nvenc;obs-qsv11;obs-text;obs-vst;obs-webrtc;oss-audio;sndio;vlc-video' \
    -DCPACK_DEBIAN_PACKAGE_NAME=obs-studio-baseline \
    -DCPACK_DEBIAN_PACKAGE_DEPENDS='qt6.2-gles-local (>= 6.2.4-1~ans1), ffmpeg6.1-ans-local (>= 6.1.6-1~ans1), rockchip-mpp-local (>= 1.3.9-1~ans1)' \
    -DCPACK_DEBIAN_PACKAGE_CONFLICTS='obs-studio, libobs0, obs-studio-gles' \
    -DCPACK_DEBIAN_PACKAGE_REPLACES='obs-studio, libobs0, obs-studio-gles' \
    -DCPACK_DEBIAN_PACKAGE_SHLIBDEPS_PRIVATE_DIRS='/usr/local/ans/lib' \
    ${EXTRA_CMAKE_FLAGS:-}
else
  echo "== 增量重配置（沿用缓存参数） =="
  cmake -S "$OBS_SRC_DIR" -B "$BUILD_DIR"
fi

if [ "${FRESH:-0}" = "1" ]; then
  echo "== 首次编译：ninja -k 0（收集全部编译错误） =="
  cmake --build "$BUILD_DIR" --parallel "$NPROC" -- -k 0
else
  echo "== 增量编译 =="
  cmake --build "$BUILD_DIR" --parallel "$NPROC"
fi

echo "== CPack 打包 =="
( cd "$BUILD_DIR" && cpack -G DEB )

mkdir -p "$OUTPUT_DIR"
find "$BUILD_DIR" -maxdepth 1 \( -name '*.deb' -o -name '*.ddeb' \) -exec cp -v {} "$OUTPUT_DIR/" \;
( cd "$OUTPUT_DIR" && sha256sum *.deb > SHA256SUMS 2>/dev/null || true )

if [ -n "${OUTPUT_UID:-}" ]; then
  chown -R "${OUTPUT_UID}:${OUTPUT_GID:-$OUTPUT_UID}" "$OUTPUT_DIR" || true
fi

echo "== BUILD OK：产物 =="
ls -la "$OUTPUT_DIR"
