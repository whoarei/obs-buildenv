# syntax=docker/dockerfile:1
#
# OBS 32.2.1 构建环境（Debian 11 arm64 / RK3588，x86_64 主机 + QEMU binfmt）
# 计划文档：docs/obs-build-environment-plan.md
#
# 阶段：
#   base        依赖装齐的 Debian 11 arm64 基础（apt + cmake 3.28 + nlohmann_json，
#               构建期工具装 /usr/local；qt6 / mpp / ffmpeg 产物统一 prefix /usr/local/ans）
#   qt6         Qt 6.2.4（-opengl es2）编译 + qt6.2-gles-local deb 打包
#   mpp         nyanmisaka/mpp jellyfin-mpp（.pc 1.3.9）编译 + rockchip-mpp-local deb 打包
#   ffmpeg6     nyanmisaka/ffmpeg-rockchip（6.1 分支）编译 + ffmpeg6.1-ans-local deb 打包
#               （构建期消费 mpp deb，运行时依赖由 rockchip-mpp-local 提供，不随包分发）
#   debs        仅汇集三个 deb 用于 --output 导出
#   obs-builder 最终开发镜像（装齐三个 deb + 基线构建所需 desktop GL 开发包），
#               入口 build-obs.sh 在 docker run 时构建挂载进来的 OBS 源码

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

ARG CMAKE_SHA256=7909cc2128ce9442c63ce674a0bfb0e4f4ce04cef667d887e15ad5670d594ba7
ARG CMAKE_VERSION=3.28.6
RUN curl -fsSL -o /tmp/cmake.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.tar.gz \
    && echo "${CMAKE_SHA256}  /tmp/cmake.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/cmake.tar.gz -C /usr/local --strip-components=1 \
    && rm /tmp/cmake.tar.gz

ARG NLOHMANN_SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
ARG NLOHMANN_VERSION=3.11.3
RUN curl -fsSL -o /tmp/json.tar.xz \
        https://github.com/nlohmann/json/releases/download/v${NLOHMANN_VERSION}/json.tar.xz \
    && echo "${NLOHMANN_SHA256}  /tmp/json.tar.xz" | sha256sum -c - \
    && mkdir -p /tmp/json-src && tar -xf /tmp/json.tar.xz -C /tmp/json-src --strip-components=1 \
    && cmake -S /tmp/json-src -B /tmp/json-build -DJSON_BuildTests=OFF \
    && cmake --install /tmp/json-build \
    && rm -rf /tmp/json.tar.xz /tmp/json-src /tmp/json-build

FROM base AS qt6
ARG QTSVG_SHA256=23ec4c14259d799bb6aaf1a07559d6b1bd2cf6d0da3ac439221ebf9e46ff3fd2
ARG QTBASE_SHA256=d9924d6fd4fa5f8e24458c87f73ef3dfc1e7c9b877a5407c040d89e6736e2634
ARG QT_VERSION=6.2.4
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
    && printf '%s\n' \
        'Package: qt6.2-gles-local' \
        'Version: 6.2.4-1~ans1' \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        'Description: Qt 6.2.4 LTS (qtbase + qtsvg) for RK3588 Debian 11' \
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
        /out/qt6/qt6.2-gles-local_6.2.4-1~ans1_arm64.deb \
    && ( cd /out/qt6 && sha256sum *.deb > SHA256SUMS )

# librockchip_mpp：设备 BSP（1.5.0-1）实为 1.3.8 代 API，缺
# mpp_buffer_sync_partial_end / MppFrameChromaFormat，无法配对
# ffmpeg-rockchip 6.1 分支；自编译 nyanmisaka/mpp jellyfin-mpp 分支
# （rockchip-linux/mpp tag 1.0.11 上游 git 树自身缺 h265d/vp9/av1 parser
# 源码无法构建，弃用），安装入 /usr/local/ans 并独立打包
# rockchip-mpp-local deb 分发（ffmpeg deb 只声明 Depends，不随包携带 mpp）。
FROM base AS mpp
ARG MPP_VERSION=1.3.9
ARG MPP_URL=https://codeload.github.com/nyanmisaka/mpp/tar.gz/a9380ef3
ARG MPP_SHA256=a82bf749bdfc6d90775f9bbc36e8d93ec826703dcafee7236c4c24436e0c0768
ARG MPP_SRCDIR=mpp-a9380ef3
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
    && printf '%s\n' \
        'Package: rockchip-mpp-local' \
        'Version: 1.3.9-1~ans1' \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        'Description: Rockchip MPP (librockchip_mpp, nyanmisaka/mpp jellyfin-mpp) for RK3588 Debian 11' \
        ' Built from nyanmisaka/mpp commit a9380ef3 (jellyfin-mpp branch, .pc' \
        ' version 1.3.9) in a Debian 11 arm64 container. Installs to' \
        ' /usr/local/ans and coexists with the device BSP mpp (the BSP' \
        ' 1.5.0-1 package ships 1.3.8-era API, too old for ffmpeg-rockchip 6.1).' \
        > /work/mpp-pkg/DEBIAN/control \
    && printf '%s\n' '/usr/local/ans/lib' \
        > /work/mpp-pkg/etc/ld.so.conf.d/rockchip-mpp-local.conf \
    && printf '%s\n' '#!/bin/sh' 'set -e' 'ldconfig 2>/dev/null || true' \
        > /work/mpp-pkg/DEBIAN/postinst \
    && chmod 0755 /work/mpp-pkg/DEBIAN/postinst \
    && dpkg-deb --build --root-owner-group /work/mpp-pkg \
        /out/mpp/rockchip-mpp-local_1.3.9-1~ans1_arm64.deb \
    && ( cd /out/mpp && sha256sum *.deb > SHA256SUMS )

FROM base AS ffmpeg6
# nyanmisaka/ffmpeg-rockchip 6.1 分支（基线 FFmpeg 6.1.6，rkmpp/rkrga 硬编解）
# 源码 tarball 以 commit + SHA-256 固定；librockchip_mpp 消费 mpp 阶段产出的
# rockchip-mpp-local deb（打包前 dpkg -r 移除，不随本 deb 分发）；
# librga 为设备 BSP 同版 deb，vendored 于 vendor/rk3588/（SHA256SUMS 固定）。
ARG FFMPEG_URL=https://codeload.github.com/nyanmisaka/ffmpeg-rockchip/tar.gz/705345ee866866d3ea5521c89c5abd9d0b0a245b
ARG FFMPEG_SHA256=d238fd9ea7f497f8a4963a65819a2044be0f5ef82633c1fca31a127c464e67f7
ARG FFMPEG_SRCDIR=ffmpeg-rockchip-705345ee866866d3ea5521c89c5abd9d0b0a245b
COPY --from=mpp /out/mpp /tmp/mpp-deb
COPY vendor/rk3588 /tmp/vendor-rk3588
RUN dpkg -i /tmp/mpp-deb/rockchip-mpp-local_1.3.9-1~ans1_arm64.deb \
    && cd /tmp/vendor-rk3588 \
    && sha256sum -c SHA256SUMS \
    && dpkg -i \
        librga2_2.2.0-1_arm64.deb \
        librga-dev_2.2.0-1_arm64.deb
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
    && printf '%s\n' \
        'Package: ffmpeg6.1-ans-local' \
        'Version: 6.1.6-1~ans1' \
        'Section: libs' \
        'Priority: optional' \
        'Architecture: arm64' \
        'Maintainer: OakSeries <local@oakseries>' \
        'Depends: rockchip-mpp-local (>= 1.3.9-1~ans1), librga2' \
        'Conflicts: ffmpeg6.1-oak-local' \
        'Replaces: ffmpeg6.1-oak-local' \
        'Description: FFmpeg 6.1.6 (nyanmisaka/ffmpeg-rockchip 6.1 branch) for RK3588 Debian 11' \
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
        /out/ffmpeg/ffmpeg6.1-ans-local_6.1.6-1~ans1_arm64.deb \
    && ( cd /out/ffmpeg && sha256sum *.deb > SHA256SUMS )

FROM scratch AS debs
COPY --from=qt6 /out/qt6 /qt6
COPY --from=mpp /out/mpp /mpp
COPY --from=ffmpeg6 /out/ffmpeg /ffmpeg

FROM base AS obs-builder
COPY --from=qt6 /out/qt6 /tmp/debs/qt6
COPY --from=mpp /out/mpp /tmp/debs/mpp
COPY --from=ffmpeg6 /out/ffmpeg /tmp/debs/ffmpeg
COPY vendor/rk3588 /tmp/vendor-rk3588
RUN cd /tmp/vendor-rk3588 \
    && sha256sum -c SHA256SUMS \
    && dpkg -i \
        librga2_2.2.0-1_arm64.deb \
        librga-dev_2.2.0-1_arm64.deb \
        /tmp/debs/mpp/rockchip-mpp-local_1.3.9-1~ans1_arm64.deb \
        /tmp/debs/qt6/qt6.2-gles-local_6.2.4-1~ans1_arm64.deb \
        /tmp/debs/ffmpeg/ffmpeg6.1-ans-local_6.1.6-1~ans1_arm64.deb \
    && rm -rf /tmp/debs
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1-mesa-dev libglvnd-dev \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/ans/bin:$PATH
ENV PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig
COPY build-obs.sh /usr/local/bin/build-obs.sh
RUN chmod 0755 /usr/local/bin/build-obs.sh
ENTRYPOINT ["/usr/local/bin/build-obs.sh"]
