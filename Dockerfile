# syntax=docker/dockerfile:1
#
# OBS 32.2.1 构建环境（Debian 11 arm64 / RK3588，x86_64 主机 + QEMU binfmt）
# 计划文档：仓库 docs/ 目录（obs-rk3588-load-analysis.md 等）
#
# 阶段：
#   base        依赖装齐的 Debian 11 arm64 基础（apt + cmake 3.28 + nlohmann_json，
#               qt6 / mesa / mpp / ffmpeg 产物统一 prefix /usr/local/ans）
#   mesa-build-base 从 base 派生并补 Meson 1.7.2 与 Mesa 专用构建依赖；
#               不使稳定的 Qt / MPP / FFmpeg 缓存失效
#   mesa25      下载官方 Mesa 25.0.7 tar.xz 并编译 + libdrm 2.4.124，
#               生成 mesa25-local deb（panfrost / EGL / GLES / GBM）
#   qt6         Qt 6.2.4（-opengl es2）编译 + qt6.2-gles-local deb 打包
#   mpp         nyanmisaka/mpp jellyfin-mpp（.pc 1.3.9）编译 + rockchip-mpp-local deb 打包
#   ffmpeg6     nyanmisaka/ffmpeg-rockchip（6.1 分支）编译 + ffmpeg6.1-ans-local deb 打包
#               （构建期消费 mpp deb，运行时依赖由 rockchip-mpp-local 提供，不随包分发）
#   debs        汇集四个依赖 deb 用于 --output 导出
#   obs-builder 最终开发镜像（装齐四个 deb + 基线构建所需 desktop GL 开发包），
#               入口 build-obs.sh 在 docker run 时构建挂载进来的 OBS 源码

# ---------------------------------------------------------------------------
# 版本号统一定义：升级任一组件只需改这一块（各 stage 用不带默认值的
# 同名 ARG 继承）。deb 包版本 = <上游版本>-<DEB_REVISION>，在 RUN 内拼接。
# 注意：带 SHA256 固定的组件改版本时必须同步更新对应 *_SHA256 / *_URL。
# ---------------------------------------------------------------------------
ARG CMAKE_VERSION=3.28.6
ARG CMAKE_SHA256=7909cc2128ce9442c63ce674a0bfb0e4f4ce04cef667d887e15ad5670d594ba7
ARG NLOHMANN_VERSION=3.11.3
ARG NLOHMANN_SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
# pypi 下载路径含内容哈希，升级 Meson 时 URL / SHA256 必须与 MESON_VERSION 一起换
ARG MESON_VERSION=1.7.2
ARG MESON_SHA256=82c6818dc81743c96de3a458f06175776ebfde4081195ea31ea6971838f25e38
ARG MESON_URL=https://files.pythonhosted.org/packages/e5/2b/46bda4ef5a7ae4135dbfe27fc0368c44e5a349a897a54fdf2cedb8dcb66e/meson-1.7.2-py3-none-any.whl
# Mesa 源码在构建时从官方 archive 下载 tar.xz 并 SHA256 校验（与
# MPP / FFmpeg 同模式）；升级时 URL / SHA256 必须与 MESA_VERSION 一起换
ARG MESA_VERSION=25.0.7
ARG MESA_DEB_REVISION=14~ans1
ARG MESA_URL=https://archive.mesa3d.org/mesa-25.0.7.tar.xz
ARG MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
ARG LIBDRM_VERSION=2.4.124
ARG LIBDRM_SHA256=ac36293f61ca4aafaf4b16a2a7afff312aa4f5c37c9fbd797de9e3c0863ca379
ARG QT_VERSION=6.2.4
ARG QT_DEB_REVISION=1~ans1
ARG QTBASE_SHA256=d9924d6fd4fa5f8e24458c87f73ef3dfc1e7c9b877a5407c040d89e6736e2634
ARG QTSVG_SHA256=23ec4c14259d799bb6aaf1a07559d6b1bd2cf6d0da3ac439221ebf9e46ff3fd2
# MPP 以 commit 固定源码，改版本时 URL / SRCDIR / SHA256 必须一起换
ARG MPP_VERSION=1.3.9
ARG MPP_DEB_REVISION=1~ans1
ARG MPP_URL=https://codeload.github.com/nyanmisaka/mpp/tar.gz/a9380ef3
ARG MPP_SRCDIR=mpp-a9380ef3
ARG MPP_SHA256=a82bf749bdfc6d90775f9bbc36e8d93ec826703dcafee7236c4c24436e0c0768
# FFmpeg 以 commit 固定源码，改版本时 URL / SRCDIR / SHA256 必须一起换
ARG FFMPEG_VERSION=6.1.6
ARG FFMPEG_DEB_REVISION=1~ans1
ARG FFMPEG_URL=https://codeload.github.com/nyanmisaka/ffmpeg-rockchip/tar.gz/705345ee866866d3ea5521c89c5abd9d0b0a245b
ARG FFMPEG_SRCDIR=ffmpeg-rockchip-705345ee866866d3ea5521c89c5abd9d0b0a245b
ARG FFMPEG_SHA256=d238fd9ea7f497f8a4963a65819a2044be0f5ef82633c1fca31a127c464e67f7
ARG LIBRGA_VERSION=2.2.0-1
ARG OBS_BUILDENV_VERSION=0.3.0

FROM arm64v8/debian:11@sha256:9690447ddac1819c12c69aca67a003baa947887c504ba6308d19ab8067d148c7 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ninja-build pkg-config git curl ca-certificates xz-utils ccache \
        perl python3 \
        libx11-dev libxext-dev libxrender-dev libxcb1-dev \
        libxcb-keysyms1-dev libxcb-util-dev libxcb-image0-dev \
        libxcb-icccm4-dev libxcb-render0-dev libxcb-render-util0-dev \
        libxcb-shape0-dev libxcb-shm0-dev libxcb-randr0-dev \
        libxcb-xinerama0-dev libxcb-xfixes0-dev libxcb-composite0-dev \
        libxcb-sync-dev libxcb-xkb-dev \
        libx11-xcb-dev libxinerama-dev libxcomposite-dev libxdamage-dev \
        libxkbcommon-dev libxkbcommon-x11-dev libxss-dev \
        libfontconfig1-dev libfreetype6-dev libglib2.0-dev \
        libdbus-1-dev libssl-dev zlib1g-dev \
        libegl1-mesa-dev libgles2-mesa-dev \
        libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
        libavutil-dev libswresample-dev libswscale-dev \
        libjansson-dev libx264-dev libpulse-dev libasound2-dev \
        libspeexdsp-dev libudev-dev libv4l-dev libpci-dev libdrm-dev \
        libcurl4-openssl-dev uthash-dev libsimde-dev \
        extra-cmake-modules libgnutls28-dev libpipewire-0.3-dev \
        libva-dev libmbedtls-dev file \
    && rm -rf /var/lib/apt/lists/*

ARG CMAKE_VERSION
ARG CMAKE_SHA256
RUN curl -fsSL -o /tmp/cmake.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.tar.gz \
    && echo "${CMAKE_SHA256}  /tmp/cmake.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/cmake.tar.gz -C /usr/local --strip-components=1 \
    && rm /tmp/cmake.tar.gz

ARG NLOHMANN_VERSION
ARG NLOHMANN_SHA256
RUN curl -fsSL -o /tmp/json.tar.xz \
        https://github.com/nlohmann/json/releases/download/v${NLOHMANN_VERSION}/json.tar.xz \
    && echo "${NLOHMANN_SHA256}  /tmp/json.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/json-src && tar -xf /tmp/json.tar.xz -C /tmp/json-src --strip-components=1 \
    && cmake -S /tmp/json-src -B /tmp/json-build -DJSON_BuildTests=OFF \
    && cmake --install /tmp/json-build \
    && rm -rf /tmp/json.tar.xz /tmp/json-src /tmp/json-build

# Mesa 源码在构建时从官方 archive 下载 tar.xz（SHA256 固定，见顶部版本区）。
# Mesa 25.0.7 要求 libdrm >= 2.4.109，Debian 11 仅有 2.4.104，故先在
# 同一 stage / 同一 prefix 构建 libdrm 2.4.124，再编译 panfrost 用户态驱动。
FROM base AS mesa-build-base
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-pip python3-mako python3-yaml python3-packaging bison flex \
        libexpat1-dev libglvnd-dev libxcb-glx0-dev libxcb-dri2-0-dev \
        libxcb-dri3-dev libxcb-present-dev libxrandr-dev \
        libxshmfence-dev libxxf86vm-dev \
    && rm -rf /var/lib/apt/lists/*
ARG MESON_VERSION
ARG MESON_SHA256
ARG MESON_URL
RUN curl -fsSL -o /tmp/meson-${MESON_VERSION}-py3-none-any.whl ${MESON_URL} \
    && echo "${MESON_SHA256}  /tmp/meson-${MESON_VERSION}-py3-none-any.whl" | sha256sum -c - \
    && python3 -m pip install --no-cache-dir --no-deps /tmp/meson-${MESON_VERSION}-py3-none-any.whl \
    && test "$(meson --version)" = "${MESON_VERSION}" \
    && rm /tmp/meson-${MESON_VERSION}-py3-none-any.whl

FROM mesa-build-base AS mesa25
ARG LIBDRM_VERSION
ARG LIBDRM_SHA256
ARG MESA_VERSION
ARG MESA_DEB_REVISION
ARG MESA_URL
ARG MESA_SHA256
ARG LIBDRM_URL=https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM_VERSION}.tar.xz
WORKDIR /build/mesa25
RUN curl -fsSL -o libdrm.tar.xz ${LIBDRM_URL} \
    && echo "${LIBDRM_SHA256}  libdrm.tar.xz" | sha256sum -c - \
    && tar -xf libdrm.tar.xz \
    && rm libdrm.tar.xz
RUN --mount=type=cache,target=/root/.cache/ccache \
    meson setup build-libdrm libdrm-${LIBDRM_VERSION} \
        --prefix=/usr/local/ans --libdir=lib --buildtype=release \
        -Dtests=false -Dinstall-test-programs=false \
        -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled \
        -Dnouveau=disabled -Dvmwgfx=disabled -Domap=disabled \
        -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled \
        -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
        -Dman-pages=disabled -Dvalgrind=disabled \
        -Dc_args=-Wno-error -Dcpp_args=-Wno-error \
    && meson compile -C build-libdrm -j "$(nproc)" \
    && meson install -C build-libdrm \
    && test "$(PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig pkg-config --modversion libdrm)" = "${LIBDRM_VERSION}"
RUN curl -fsSL -o mesa.tar.xz ${MESA_URL} \
    && echo "${MESA_SHA256}  mesa.tar.xz" | sha256sum -c - \
    && mkdir src && tar -xJf mesa.tar.xz -C src --strip-components=1 \
    && rm mesa.tar.xz \
    && test "$(cat src/VERSION)" = "${MESA_VERSION}"
ENV PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig
RUN --mount=type=cache,target=/root/.cache/ccache \
    CC='ccache gcc' CXX='ccache g++' meson setup build-mesa src \
        --prefix=/usr/local/ans --libdir=lib --buildtype=release \
        -Dplatforms=x11 -Dgallium-drivers=panfrost,softpipe '-Dvulkan-drivers=' \
        -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled \
        -Dopengl=true -Dglx=dri -Dglvnd=enabled -Dshared-glapi=enabled \
        -Dllvm=disabled -Dshared-llvm=disabled \
        -Dgallium-vdpau=disabled -Dgallium-va=disabled \
        -Dgallium-xa=disabled -Dgallium-rusticl=false \
        -Dgallium-opencl=disabled '-Dvideo-codecs=' \
        -Dbuild-tests=false '-Dtools=' -Dosmesa=false \
        -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
        -Dzstd=disabled -Dxmlconfig=enabled \
    && meson compile -C build-mesa -j "$(nproc)" \
    && meson install -C build-mesa
COPY mesa-egl-gles-smoke.c /tmp/mesa-egl-gles-smoke.c
COPY mesa-glamor-shader-smoke.c /tmp/mesa-glamor-shader-smoke.c
COPY mesa25-run /usr/local/ans/bin/mesa25-run
COPY --chmod=0755 packaging/mesa25-local/mesa25-xorg \
    /usr/local/ans/bin/mesa25-xorg
COPY packaging/mesa25-local/01-xorg-glamor.conf \
    /usr/local/ans/share/drirc.d/01-xorg-glamor.conf
RUN cc -O2 -Wall -Wextra -o /usr/local/ans/bin/mesa-egl-gles-smoke \
        /tmp/mesa-egl-gles-smoke.c -lEGL -lGLESv2 \
    && cc -O2 -Wall -Wextra -o /usr/local/ans/bin/mesa-glamor-shader-smoke \
        /tmp/mesa-glamor-shader-smoke.c -lEGL -lGL \
    && rm /tmp/mesa-egl-gles-smoke.c /tmp/mesa-glamor-shader-smoke.c \
    && chmod 0755 /usr/local/ans/bin/mesa25-run \
    && test -f /usr/local/ans/lib/dri/panfrost_dri.so \
    && test -f /usr/local/ans/lib/dri/panthor_dri.so \
    && test -f /usr/local/ans/lib/dri/rockchip_dri.so \
    && test -f /usr/local/ans/lib/dri/swrast_dri.so \
    && test -f /usr/local/ans/lib/libEGL_mesa.so.0 \
    && test -f /usr/local/ans/lib/libgbm.so.1 \
    && test -f /usr/local/ans/lib/libdrm.so.2 \
    && sed -i 's#"libEGL_mesa.so.0"#"/usr/local/ans/lib/libEGL_mesa.so.0"#' \
        /usr/local/ans/share/glvnd/egl_vendor.d/50_mesa.json \
    && grep -q '"/usr/local/ans/lib/libEGL_mesa.so.0"' \
        /usr/local/ans/share/glvnd/egl_vendor.d/50_mesa.json
COPY packaging/mesa25-local/postinst packaging/mesa25-local/postrm \
    /work/mesa-maintainer-scripts/
COPY packaging/mesa25-local/lightdm.conf \
    /work/mesa-lightdm.conf
COPY packaging/mesa25-local/lightdm-xserver.conf \
    /work/mesa-lightdm-xserver.conf
COPY packaging/mesa25-local/20-modesetting.conf \
    /usr/local/ans/share/obs-buildenv/mesa25-xorg.conf
RUN mkdir -p /usr/local/ans/share/obs-buildenv/xorg.conf.d
RUN mkdir -p /work/mesa-pkg/usr/local /work/mesa-pkg/DEBIAN \
        /work/mesa-pkg/etc/ld.so.conf.d \
        /work/mesa-pkg/etc/systemd/system/lightdm.service.d \
        /work/mesa-pkg/etc/lightdm/lightdm.conf.d /out/mesa \
    && cp -a /usr/local/ans /work/mesa-pkg/usr/local/ \
    && cp /work/mesa-lightdm.conf \
        /work/mesa-pkg/etc/systemd/system/lightdm.service.d/mesa25-local.conf \
    && cp /work/mesa-lightdm-xserver.conf \
        /work/mesa-pkg/etc/lightdm/lightdm.conf.d/90-mesa25-local.conf \
    && cp /work/mesa-maintainer-scripts/postinst \
        /work/mesa-maintainer-scripts/postrm /work/mesa-pkg/DEBIAN/ \
    && MESA_DEB_VERSION="${MESA_VERSION}-${MESA_DEB_REVISION}" \
    && printf '%s\n' \
        'Package: mesa25-local' \
        "Version: ${MESA_DEB_VERSION}" \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        "Provides: mesa25-rk3588-local (= ${MESA_DEB_VERSION})" \
        'Conflicts: mesa25-rk3588-local' \
        'Replaces: mesa25-rk3588-local' \
        'Depends: xserver-common (>= 2:1.20.11-1+deb11u17),' \
        ' xserver-xorg-core (>= 2:1.20.11-1+deb11u17),' \
        ' libc6, libgcc-s1, libstdc++6, libegl1, libgles2, libgl1, libglvnd0,' \
        ' libexpat1, libudev1,' \
        ' libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0,' \
        ' libxcb-glx0, libxcb-present0, libxcb-randr0, libxcb-shm0,' \
        ' libxcb-sync1, libxcb-xfixes0, libxext6, libxfixes3,' \
        ' libxshmfence1, libxxf86vm1, zlib1g' \
        "Description: Mesa ${MESA_VERSION} panfrost EGL/GLES/GBM stack for RK3588 Debian 11" \
        " Built with libdrm ${LIBDRM_VERSION} for the panthor kernel driver. Installs" \
        ' runtime libraries, development metadata, and an EGL/GLES smoke test' \
        ' under /usr/local/ans. Keeps Debian Mesa/GLVND packages installed while' \
        ' making Mesa 25 the default LightDM/Xorg and system graphics stack.' \
        ' Requires the Debian Xorg security update without the broken BSP' \
        ' FlipFB extension, and uses glamor/DRI3 without page flips.' \
        > /work/mesa-pkg/DEBIAN/control \
    && printf '%s\n' '/usr/local/ans/lib' \
        > /work/mesa-pkg/etc/ld.so.conf.d/00-mesa25-local.conf \
    && chmod 0755 /work/mesa-pkg/DEBIAN/postinst /work/mesa-pkg/DEBIAN/postrm \
    && dpkg-deb --build --root-owner-group /work/mesa-pkg \
        "/out/mesa/mesa25-local_${MESA_DEB_VERSION}_arm64.deb" \
    && ( cd /out/mesa && sha256sum *.deb > SHA256SUMS )

FROM scratch AS mesa-debs
COPY --from=mesa25 /out/mesa /

FROM base AS qt6
ARG QT_VERSION
ARG QTBASE_SHA256
ARG QTSVG_SHA256
ARG QT_DEB_REVISION
WORKDIR /build/qt
RUN curl -fsSL -O \
        https://download.qt.io/archive/qt/6.2/${QT_VERSION}/submodules/qtbase-everywhere-src-${QT_VERSION}.tar.xz \
    && echo "${QTBASE_SHA256}  qtbase-everywhere-src-${QT_VERSION}.tar.xz" | sha256sum -c - \
    && tar -xf qtbase-everywhere-src-${QT_VERSION}.tar.xz \
    && rm qtbase-everywhere-src-${QT_VERSION}.tar.xz
RUN --mount=type=cache,target=/root/.cache/ccache mkdir -p /build/qt/build-qtbase \
    && cd /build/qt/build-qtbase \
    && ../qtbase-everywhere-src-${QT_VERSION}/configure \
        -prefix /usr/local/ans \
        -opensource -confirm-license \
        -release \
        -opengl es2 \
        -xcb -xcb-xlib \
        -dbus-linked -glib \
        -nomake examples -nomake tests -no-pch \
        -- -DCMAKE_C_COMPILER_LAUNCHER=ccache \
           -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build . --parallel "$(nproc)" \
    && cmake --install .
RUN curl -fsSL -O \
        https://download.qt.io/archive/qt/6.2/${QT_VERSION}/submodules/qtsvg-everywhere-src-${QT_VERSION}.tar.xz \
    && echo "${QTSVG_SHA256}  qtsvg-everywhere-src-${QT_VERSION}.tar.xz" | sha256sum -c - \
    && tar -xf qtsvg-everywhere-src-${QT_VERSION}.tar.xz \
    && rm qtsvg-everywhere-src-${QT_VERSION}.tar.xz
RUN --mount=type=cache,target=/root/.cache/ccache /usr/local/ans/bin/qt-cmake \
        -S /build/qt/qtsvg-everywhere-src-${QT_VERSION} \
        -B /build/qt/build-qtsvg \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build /build/qt/build-qtsvg --parallel "$(nproc)" \
    && cmake --install /build/qt/build-qtsvg
RUN if readelf -d /usr/local/ans/lib/libQt6Gui.so.6 | grep -q 'NEEDED.*libGL\.so'; then \
        echo "ERROR: libQt6Gui.so.6 links desktop libGL" >&2; exit 1; \
    fi
RUN mkdir -p /work/qt6-pkg/usr/local /work/qt6-pkg/DEBIAN /work/qt6-pkg/etc/ld.so.conf.d /out/qt6 \
    && cp -a /usr/local/ans /work/qt6-pkg/usr/local/ \
    && QT_DEB_VERSION="${QT_VERSION}-${QT_DEB_REVISION}" \
    && printf '%s\n' \
        'Package: qt6.2-gles-local' \
        "Version: ${QT_DEB_VERSION}" \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        "Description: Qt ${QT_VERSION} LTS (qtbase + qtsvg) for RK3588 Debian 11" \
        ' Built in a Debian 11 arm64 container with -opengl es2 (GLES-only,' \
        ' no desktop GL). Installs to /usr/local/ans and coexists with the' \
        ' system Qt5 packages.' \
        > /work/qt6-pkg/DEBIAN/control \
    && printf '%s\n' '/usr/local/ans/lib' \
        > /work/qt6-pkg/etc/ld.so.conf.d/qt6.2-gles-local.conf \
    && printf '%s\n' '#!/bin/sh' 'set -e' 'ldconfig 2>/dev/null || true' \
        > /work/qt6-pkg/DEBIAN/postinst \
    && chmod 0755 /work/qt6-pkg/DEBIAN/postinst \
    && dpkg-deb --build --root-owner-group /work/qt6-pkg \
        "/out/qt6/qt6.2-gles-local_${QT_DEB_VERSION}_arm64.deb" \
    && ( cd /out/qt6 && sha256sum *.deb > SHA256SUMS )

# librockchip_mpp：设备 BSP（1.5.0-1）实为 1.3.8 代 API，缺
# mpp_buffer_sync_partial_end / MppFrameChromaFormat，无法配对
# ffmpeg-rockchip 6.1 分支；自编译 nyanmisaka/mpp jellyfin-mpp 分支
# （rockchip-linux/mpp tag 1.0.11 上游 git 树自身缺 h265d/vp9/av1 parser
# 源码无法构建，弃用），安装入 /usr/local/ans 并独立打包
# rockchip-mpp-local deb 分发（ffmpeg deb 只声明 Depends，不随包携带 mpp）。
FROM base AS mpp
ARG MPP_VERSION
ARG MPP_URL
ARG MPP_SHA256
ARG MPP_SRCDIR
ARG MPP_DEB_REVISION
WORKDIR /build/mpp
RUN curl -fsSL -o mpp.tar.gz ${MPP_URL} \
    && echo "${MPP_SHA256}  mpp.tar.gz" | sha256sum -c - \
    && tar -xzf mpp.tar.gz \
    && rm mpp.tar.gz
RUN --mount=type=cache,target=/root/.cache/ccache cmake -S /build/mpp/${MPP_SRCDIR} -B /build/mpp/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local/ans \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build /build/mpp/build --parallel "$(nproc)" \
    && cmake --install /build/mpp/build
RUN test -f /usr/local/ans/lib/pkgconfig/rockchip_mpp.pc \
    && grep -q "Version: ${MPP_VERSION}" /usr/local/ans/lib/pkgconfig/rockchip_mpp.pc \
    && grep -rq mpp_buffer_sync_partial_end /usr/local/ans/include/rockchip/
RUN mkdir -p /work/mpp-pkg/usr/local /work/mpp-pkg/DEBIAN /work/mpp-pkg/etc/ld.so.conf.d /out/mpp \
    && cp -a /usr/local/ans /work/mpp-pkg/usr/local/ \
    && MPP_DEB_VERSION="${MPP_VERSION}-${MPP_DEB_REVISION}" \
    && printf '%s\n' \
        'Package: rockchip-mpp-local' \
        "Version: ${MPP_DEB_VERSION}" \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        'Description: Rockchip MPP (librockchip_mpp, nyanmisaka/mpp jellyfin-mpp) for RK3588 Debian 11' \
        ' Built from nyanmisaka/mpp commit a9380ef3 (jellyfin-mpp branch, .pc' \
        " version ${MPP_VERSION}) in a Debian 11 arm64 container. Installs to" \
        ' /usr/local/ans and coexists with the device BSP mpp (the BSP' \
        ' 1.5.0-1 package ships 1.3.8-era API, too old for ffmpeg-rockchip 6.1).' \
        > /work/mpp-pkg/DEBIAN/control \
    && printf '%s\n' '/usr/local/ans/lib' \
        > /work/mpp-pkg/etc/ld.so.conf.d/rockchip-mpp-local.conf \
    && printf '%s\n' '#!/bin/sh' 'set -e' 'ldconfig 2>/dev/null || true' \
        > /work/mpp-pkg/DEBIAN/postinst \
    && chmod 0755 /work/mpp-pkg/DEBIAN/postinst \
    && dpkg-deb --build --root-owner-group /work/mpp-pkg \
        "/out/mpp/rockchip-mpp-local_${MPP_DEB_VERSION}_arm64.deb" \
    && ( cd /out/mpp && sha256sum *.deb > SHA256SUMS )

FROM base AS ffmpeg6
# nyanmisaka/ffmpeg-rockchip 6.1 分支（基线 FFmpeg 6.1.6，rkmpp/rkrga 硬编解）
# 源码 tarball 以 commit + SHA-256 固定；librockchip_mpp 消费 mpp 阶段产出的
# rockchip-mpp-local deb（打包前 dpkg -r 移除，不随本 deb 分发）；
# librga 为设备 BSP 同版 deb，vendored 于 vendor/rk3588/（SHA256SUMS 固定）。
ARG FFMPEG_VERSION
ARG FFMPEG_URL
ARG FFMPEG_SHA256
ARG FFMPEG_SRCDIR
ARG FFMPEG_DEB_REVISION
ARG LIBRGA_VERSION
ARG MPP_VERSION
ARG MPP_DEB_REVISION
COPY --from=mpp /out/mpp /tmp/mpp-deb
COPY vendor/rk3588 /tmp/vendor-rk3588
RUN dpkg -i "/tmp/mpp-deb/rockchip-mpp-local_${MPP_VERSION}-${MPP_DEB_REVISION}_arm64.deb" \
    && cd /tmp/vendor-rk3588 \
    && sha256sum -c SHA256SUMS \
    && dpkg -i \
        "librga2_${LIBRGA_VERSION}_arm64.deb" \
        "librga-dev_${LIBRGA_VERSION}_arm64.deb"
ENV PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig
WORKDIR /build/ffmpeg
RUN curl -fsSL -o ffmpeg-rockchip.tar.gz ${FFMPEG_URL} \
    && echo "${FFMPEG_SHA256}  ffmpeg-rockchip.tar.gz" | sha256sum -c - \
    && tar -xzf ffmpeg-rockchip.tar.gz \
    && rm ffmpeg-rockchip.tar.gz
RUN --mount=type=cache,target=/root/.cache/ccache cd /build/ffmpeg/${FFMPEG_SRCDIR} \
    && ./configure \
        --prefix=/usr/local/ans \
        --enable-shared --disable-static \
        --enable-gpl --enable-libx264 \
        --enable-swscale --enable-swresample \
        --enable-avdevice --enable-avfilter \
        --enable-network --enable-gnutls \
        --enable-rkmpp --enable-rkrga --enable-libdrm --enable-version3 \
        --disable-doc --disable-debug --disable-ffplay \
        --cc='ccache gcc' \
        --extra-ldflags='-Wl,-rpath,/usr/local/ans/lib' \
    && make -j"$(nproc)" \
    && make install
RUN test -x /usr/local/ans/bin/ffmpeg \
    && test -x /usr/local/ans/bin/ffprobe \
    && /usr/local/ans/bin/ffmpeg -hide_banner -decoders 2>/dev/null | grep -q rkmpp \
    && /usr/local/ans/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -q rkmpp \
    && ! ldd -r /usr/local/ans/lib/libavcodec.so.60 2>&1 | grep -q 'not found'
RUN dpkg -r rockchip-mpp-local \
    && mkdir -p /work/ffmpeg-pkg/usr/local /work/ffmpeg-pkg/DEBIAN /work/ffmpeg-pkg/etc/ld.so.conf.d /out/ffmpeg \
    && cp -a /usr/local/ans /work/ffmpeg-pkg/usr/local/ \
    && FFMPEG_DEB_VERSION="${FFMPEG_VERSION}-${FFMPEG_DEB_REVISION}" \
    && MPP_DEB_VERSION="${MPP_VERSION}-${MPP_DEB_REVISION}" \
    && printf '%s\n' \
        'Package: ffmpeg6.1-ans-local' \
        "Version: ${FFMPEG_DEB_VERSION}" \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        "Depends: rockchip-mpp-local (>= ${MPP_DEB_VERSION}), librga2" \
        'Conflicts: ffmpeg6.1-oak-local' \
        'Replaces: ffmpeg6.1-oak-local' \
        "Description: FFmpeg ${FFMPEG_VERSION} (nyanmisaka/ffmpeg-rockchip 6.1 branch) for RK3588 Debian 11" \
        ' Shared libraries with rkmpp/rkrga hardware codec support, built in a' \
        ' Debian 11 arm64 container. Installs to /usr/local/ans and' \
        ' coexists with the system FFmpeg 4.3 (SONAMEs differ).' \
        ' librockchip_mpp is provided by the rockchip-mpp-local package.' \
        > /work/ffmpeg-pkg/DEBIAN/control \
    && printf '%s\n' '/usr/local/ans/lib' \
        > /work/ffmpeg-pkg/etc/ld.so.conf.d/ffmpeg6.1-ans-local.conf \
    && printf '%s\n' '#!/bin/sh' 'set -e' 'ldconfig 2>/dev/null || true' \
        > /work/ffmpeg-pkg/DEBIAN/postinst \
    && chmod 0755 /work/ffmpeg-pkg/DEBIAN/postinst \
    && dpkg-deb --build --root-owner-group /work/ffmpeg-pkg \
        "/out/ffmpeg/ffmpeg6.1-ans-local_${FFMPEG_DEB_VERSION}_arm64.deb" \
    && ( cd /out/ffmpeg && sha256sum *.deb > SHA256SUMS )

FROM scratch AS debs
COPY --from=mesa25 /out/mesa /mesa
COPY --from=qt6 /out/qt6 /qt6
COPY --from=mpp /out/mpp /mpp
COPY --from=ffmpeg6 /out/ffmpeg /ffmpeg

FROM base AS obs-builder
ARG OBS_BUILDENV_VERSION
ARG MESA_VERSION
ARG MESA_DEB_REVISION
ARG QT_VERSION
ARG QT_DEB_REVISION
ARG MPP_VERSION
ARG MPP_DEB_REVISION
ARG FFMPEG_VERSION
ARG FFMPEG_DEB_REVISION
ARG LIBRGA_VERSION
LABEL org.opencontainers.image.title="obs-buildenv" \
      org.opencontainers.image.description="OBS build environment for RK3588 Debian 11 arm64" \
      org.opencontainers.image.version="${OBS_BUILDENV_VERSION}" \
      org.opencontainers.image.source="https://github.com/whoarei/obs-buildenv"
COPY --from=mesa25 /out/mesa /tmp/debs/mesa
COPY --from=mesa25 /out/mesa /opt/obs-buildenv/debs/mesa
COPY --from=qt6 /out/qt6 /tmp/debs/qt6
COPY --from=mpp /out/mpp /tmp/debs/mpp
COPY --from=ffmpeg6 /out/ffmpeg /tmp/debs/ffmpeg
COPY vendor/rk3588 /tmp/vendor-rk3588
RUN cd /tmp/vendor-rk3588 \
    && sha256sum -c SHA256SUMS \
    && dpkg -i \
        "librga2_${LIBRGA_VERSION}_arm64.deb" \
        "librga-dev_${LIBRGA_VERSION}_arm64.deb" \
        "/tmp/debs/mesa/mesa25-local_${MESA_VERSION}-${MESA_DEB_REVISION}_arm64.deb" \
        "/tmp/debs/mpp/rockchip-mpp-local_${MPP_VERSION}-${MPP_DEB_REVISION}_arm64.deb" \
        "/tmp/debs/qt6/qt6.2-gles-local_${QT_VERSION}-${QT_DEB_REVISION}_arm64.deb" \
        "/tmp/debs/ffmpeg/ffmpeg6.1-ans-local_${FFMPEG_VERSION}-${FFMPEG_DEB_REVISION}_arm64.deb" \
    && rm -rf /tmp/debs
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1-mesa-dev libglvnd-dev \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/ans/bin:$PATH
ENV PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig
ENV __EGL_VENDOR_LIBRARY_FILENAMES=/usr/local/ans/share/glvnd/egl_vendor.d/50_mesa.json
ENV LIBGL_DRIVERS_PATH=/usr/local/ans/lib/dri
ENV GBM_BACKENDS_PATH=/usr/local/ans/lib/gbm
COPY --chmod=0755 build-obs.sh /usr/local/bin/build-obs.sh
COPY cmake/ /usr/local/share/obs-buildenv/
ENTRYPOINT ["/usr/local/bin/build-obs.sh"]
