# obs-buildenv — OBS 构建环境（Debian 11 arm64 / RK3588）

面向 RK3588（Debian 11 arm64）的 OBS 32.2.1 构建环境。上游依赖 Mesa、Qt、FFmpeg、Rockchip MPP 已预编译成 deb 并发布，容器镜像负责编译 OBS 源码并产出 deb。

镜像与依赖均为 **linux/arm64**；在 x86_64 主机上通过 QEMU 用户态模拟运行。

## 获取依赖 deb（GitHub Release）

每次推送 `v*` tag 会触发 CI：构建镜像、导出四个依赖 deb 并自动发布到对应 tag 的 **Release**。workflow 也可手动触发，在原生 arm64 runner 构建并上传 Actions artifact，但不会创建 Release。

到 [Releases](https://github.com/whoarei/obs-buildenv/releases) 下载附件：

| 包 | 版本 | 作用 |
| --- | --- | --- |
| `mesa25-local` | 25.0.7 | Mesa Panfrost EGL/GLES/GLX/GBM + libdrm 2.4.124，并把 LightDM/Xorg 默认栈切到 panthor |
| `qt6.2-gles-local` | 6.2.4 | Qt 6.2.4（qtbase + qtsvg，`-opengl es2`，无 desktop GL） |
| `rockchip-mpp-local` | 1.3.9 | nyanmisaka/mpp jellyfin-mpp，硬编解码库 |
| `ffmpeg6.1-ans-local` | 6.1.6 | ffmpeg-rockchip 6.1，rkmpp/rkrga 硬编解 |

- 四个包统一安装到 `/usr/local/ans`。`mesa25-local` 保留 Debian Mesa、GLVND 和
  BSP libmali 包以维持 APT 关系，但停用不兼容的 G52 libmali loader 路径，并让
  Mesa 25 成为系统、LightDM 和 Xorg 的默认图形栈。
- 设备 BSP 的 Rockchip 定制 Xorg `modesetting` 驱动会自动进入损坏的 `FlipFB`
  窗口复制路径。`mesa25-local` 要求 Debian 官方 Xorg 安全更新
  `2:1.20.11-1+deb11u17` 或更新版本，保留 `glamor + DRI3` 和 Panfrost 硬件加速，
  同时恢复正常的窗口、panel 和标准 Xorg 光标。
- `ffmpeg6.1-ans-local` 依赖 `rockchip-mpp-local` 与 `librga2`（librga 为设备 BSP 包，目标机通常已自带）。
- Release 附件含统一的 `SHA256SUMS`，下载后先校验：
  ```sh
  sha256sum -c SHA256SUMS
  ```

## 获取镜像

镜像发布在 GitHub Container Registry，tag 与 Release 对齐（`latest` 指向最新 tag）：

```sh
docker pull --platform linux/arm64 ghcr.io/whoarei/obs-buildenv:latest
```

Mesa 与 OBS 的最短安装、升级和回滚步骤见
[MESA-OBS-INSTALL.md](docs/MESA-OBS-INSTALL.md)。

### 在 x86_64 主机上运行

arm64 镜像需要 QEMU 模拟（先注册 binfmt，需要 root）：

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

之后所有 `docker run` 都要带 `--platform linux/arm64`。注意：模拟执行性能约为原生的 1/10~1/20，且运行时硬解码（librockchip_mpp）无法走硬件，只能软件解码。

## 编译 OBS 源码

镜像入口 `build-obs.sh` 会自动编译挂载进来的 OBS checkout 并产出 deb，不需要提前装依赖：

```sh
docker run --rm \
  --platform linux/arm64 \
  -v /path/to/obs-studio:/src/obs-studio \
  -v $PWD/obs-binary:/output \
  -v builddir:/build \
  -v ccache:/root/.cache/ccache \
  -e OUTPUT_UID=$(id -u) -e OUTPUT_GID=$(id -g) \
  ghcr.io/whoarei/obs-buildenv:latest
```

- 容器入口：找源码 → cmake 配置（仅首次）→ ninja 编译（首次 `-k 0` 收集全部错误，之后增量 + ccache）→ CPack 出 deb → 产物（deb / ddeb / `SHA256SUMS`）拷到 `/output`（即本机 `obs-binary/`）。
- 任意一份 OBS checkout 均可直接编译，镜像不含 OBS 源码快照。
- OBS 程序、库、插件和运行数据保留在 `/usr/local/ans`；CPack 仅把 `.desktop`、图标和 metainfo 安装到标准 `/usr/share`，桌面入口使用绝对命令 `/usr/local/ans/bin/obs`。
- `builddir` 命名卷保存 CMake 构建树，加速增量编译；配置异常时 `docker volume rm builddir` 后重跑即全量重配。
- `ccache` 命名卷缓存编译产物，建议保留以加速反复编译（删除也不影响正确性）。
- `build-obs.sh` 是镜像的入口文件（ENTRYPOINT），和 `cmake/` 下的 CPack 辅助脚本一起内置在 `obs-buildenv` 镜像中，正常构建无需额外挂载；文件更新后需要重新构建或发布镜像。本地修改了入口脚本但不想重建镜像时，可用卷直接覆盖镜像内副本立即生效：

  ```sh
  -v $PWD/build-obs.sh:/usr/local/bin/build-obs.sh:ro
  ```

  CPack 辅助脚本同理，挂载到 `/usr/local/share/obs-buildenv/` 下的同名路径即可。
- 追加 cmake 参数：`-e EXTRA_CMAKE_FLAGS='-DXXX=ON'`（仅首次配置生效）。
- 默认产物包名为 `obs-studio`；只有构建独立实验变体时才用
  `-e DEBIAN_PACKAGE_NAME=obs-studio-<variant>` 覆盖。
- 镜像内已设 `PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig` 与 `PATH=/usr/local/ans/bin:...`，OBS 的 FindFFmpeg 优先选中自编译 FFmpeg 6.1.6 而非系统 4.3。

正式 RK3588 交付分支为 `rk3588/32.2.1-rkmpp`：它以 desktop OpenGL baseline
为基础，仅加入媒体源 RKMPP 硬解码，不包含 GLES 后端。产物包名为 `obs-studio`，
与依赖 deb 一同安装：

```sh
dpkg -i mesa25-local*.deb qt6.2-gles-local*.deb rockchip-mpp-local*.deb \
  ffmpeg6.1-ans-local*.deb obs-studio-32.2.1-*-Linux.deb
```

### 构建 OBS 32.2.1 GLES 分支

GLES 移植分支使用独立 `libobs-gles` 图形模块；构建时必须关闭 desktop OpenGL，并关闭当前尚未支持的 Wayland 路径：

```sh
docker run --rm \
  --platform linux/arm64 \
  -v /path/to/obs-studio:/src/obs-studio:ro \
  -v $PWD/obs-binary-gles:/output \
  -v obs32-gles-build:/build \
  -v ccache:/root/.cache/ccache \
  -e EXTRA_CMAKE_FLAGS='-DENABLE_OPENGL=OFF -DENABLE_GLES=ON' \
  -e DEBIAN_PACKAGE_NAME=obs-studio-gles \
  -e OUTPUT_UID=$(id -u) -e OUTPUT_GID=$(id -g) \
  ghcr.io/whoarei/obs-buildenv:latest
```

生成的 deb control 字段为 `Package: obs-studio-gles`，并与 `obs-studio`、`libobs0`、`obs-studio-baseline` 冲突/替换，避免和 desktop OpenGL 版本混装。若临时使用尚未包含当前打包逻辑的旧构建镜像，才需要挂载本地入口和桌面集成脚本：

```sh
-v $PWD/build-obs.sh:/usr/local/bin/build-obs.sh:ro \
-v $PWD/cmake/cpack-desktop-integration.cmake:/usr/local/share/obs-buildenv/cpack-desktop-integration.cmake:ro
```

构建后的设备安装、GLES/RKMPP 硬解、软件回退、循环播放和录制回归步骤见 [RK3588-GLES-RKMPP-TEST.md](docs/RK3588-GLES-RKMPP-TEST.md)。


## 项目结构

| 文件/目录 | 作用 |
| --- | --- |
| `Dockerfile` | 多阶段：base → mesa25 / qt6 / mpp / ffmpeg6（依赖编译 + 打 deb，统一 prefix `/usr/local/ans`）→ obs-buildenv（开发镜像） |
| `docs/` | 安装手册、构建打包说明与各项设备测试报告（入口见上文各节链接） |
| `mesa25-run` / `mesa-egl-gles-smoke.c` | 固定 Mesa 运行环境和验证 EGL 初始化、GLES 清屏、像素读回 |
| `mesa-glamor-shader-smoke.c` | 复现 Debian 11 Xorg 1.20 glamor shader，验证 Mesa 25 的 Xorg 专用 GLSL 兼容规则 |
| `libdrm-kms-screen-test.c` | 独占 DRM master，验证 HDMI KMS mode set、扫描输出和 page-flip |
| `build-obs.sh` | 容器入口，`docker run` 时自动编译挂载进来的 OBS 源码 |
| `cmake/cpack-desktop-integration.cmake` | 在 CPack 暂存目录中将菜单、图标和 metainfo 移到标准 XDG 路径 |
| `vendor/rk3588/` | 设备 BSP 同版 librga deb（SHA-256 固定，构建期依赖） |
| `.github/workflows/docker-build.yml` | 原生 arm64 CI：tag 发布 deb/镜像；也支持手动构建 Actions artifact |
