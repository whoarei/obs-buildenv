# obs-buildenv — OBS 构建环境（Debian 11 arm64 / RK3588）

面向 RK3588（Debian 11 arm64）的 OBS 32.2.1 构建环境。上游依赖 Mesa、Qt、FFmpeg、Rockchip MPP 已预编译成 deb 并发布，容器镜像负责编译 OBS 源码并产出 deb。

镜像与依赖均为 **linux/arm64**；在 x86_64 主机上通过 QEMU 用户态模拟运行。

## 获取依赖 deb（GitHub Release）

每次推送 `v*` tag 会触发 CI：构建镜像、导出四个依赖 deb 并自动发布到对应 tag 的 **Release**。workflow 手动触发或推送 `mesa-25.0.7` 分支时也会在原生 arm64 runner 构建，但只上传 Actions artifact，不创建 Release。

到 [Releases](https://github.com/whoarei/obs-buildenv/releases) 下载附件：

| 包 | 版本 | 作用 |
| --- | --- | --- |
| `mesa25-rk3588-local` | 25.0.7 | Mesa panfrost EGL/GLES/GBM + libdrm 2.4.124，支持 panthor 内核驱动 |
| `qt6.2-gles-local` | 6.2.4 | Qt 6.2.4（qtbase + qtsvg，`-opengl es2`，无 desktop GL） |
| `rockchip-mpp-local` | 1.3.9 | nyanmisaka/mpp jellyfin-mpp，硬编解码库 |
| `ffmpeg6.1-ans-local` | 6.1.6 | ffmpeg-rockchip 6.1，rkmpp/rkrga 硬编解 |

- 四个包统一安装到 `/usr/local/ans`。Mesa 通过 GLVND vendor JSON 和 DRI 路径选择，Qt/FFmpeg 依靠独立 SONAME 或前缀，与 Debian 11 系统包共存。
- `ffmpeg6.1-ans-local` 依赖 `rockchip-mpp-local` 与 `librga2`（librga 为设备 BSP 包，目标机通常已自带）。
- 附件含各目录的 `SHA256SUMS`，下载后先校验：
  ```sh
  sha256sum -c mesa/SHA256SUMS qt6/SHA256SUMS mpp/SHA256SUMS ffmpeg/SHA256SUMS
  ```

## 获取镜像

镜像发布在 GitHub Container Registry，tag 与 Release 对齐（`latest` 指向最新 tag）：

```sh
docker pull --platform linux/arm64 ghcr.io/whoarei/obs-buildenv:latest
```

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
- `build-obs.sh` 和 `cmake/` 下的 CPack 辅助脚本已内置到 `obs-builder` 镜像，正常构建无需额外挂载；文件更新后需要重新构建或发布镜像。
- 追加 cmake 参数：`-e EXTRA_CMAKE_FLAGS='-DXXX=ON'`（仅首次配置生效）。
- 自定义产物包名：`-e DEBIAN_PACKAGE_NAME=obs-studio-<version>`（默认 `obs-studio-baseline`，编非基线版本时建议覆盖）。
- 镜像内已设 `PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig` 与 `PATH=/usr/local/ans/bin:...`，OBS 的 FindFFmpeg 优先选中自编译 FFmpeg 6.1.6 而非系统 4.3。

产物 `obs-studio-baseline` deb 安装到目标机时，与依赖 deb 一同安装（`dpkg -i mesa25-rk3588-local*.deb qt6.2-gles-local*.deb rockchip-mpp-local*.deb ffmpeg6.1-ans-local*.deb obs-studio-baseline*.deb`）。

### Mesa 25.0.7 源码上下文

Mesa 使用仓库外的源码树，不复制源码快照进本仓库。本地默认读取 `../mesa-25.0.7`，并要求其中 `VERSION` 严格为 `25.0.7`：

```sh
git -C ../mesa worktree add --detach ../mesa-25.0.7 mesa-25.0.7
./docker-build.sh
```

也可用 `MESA_SOURCE=/path/to/mesa-25.0.7 ./docker-build.sh` 覆盖。GitHub workflow 从 Mesa 官方 GitLab 浅克隆 `mesa-25.0.7` 标签，并核对 commit `742a20f48c59e8649533c84c4d49dd95b403f5da` 后作为 BuildKit named context 注入同一份 `Dockerfile`。

安装 Mesa deb 后可执行真实 EGL/GLES 渲染读回测试：

```sh
/usr/local/ans/bin/mesa25-run /usr/local/ans/bin/mesa-egl-gles-smoke
```

`mesa25-run` 除了固定 Mesa vendor、DRI、GBM 路径，还会显式选择 Debian
GLVND dispatcher。部分 RK3588 BSP 会让厂商 Mali `libEGL.so.1` 在
`ld.so.cache` 中排到 GLVND 前面，直接启动程序会绕过 Mesa vendor；需要使用
Mesa 25 的 EGL/GLES 程序统一通过该入口启动。OBS deb 的桌面文件已自动使用
`mesa25-run`，命令行启动可执行：

```sh
/usr/local/ans/bin/mesa25-run /usr/local/ans/bin/obs
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

构建后的设备安装、GLES/RKMPP 硬解、软件回退、循环播放和录制回归步骤见 [RK3588-GLES-RKMPP-TEST.md](RK3588-GLES-RKMPP-TEST.md)。

## 基线构建配置

默认按上游基线：桌面 OpenGL 渲染后端（不定义 `OBS_USE_GLES`）、`ENABLE_WAYLAND=OFF`（镜像无 wayland 依赖）、`ENABLE_SCRIPTING=OFF`、`ENABLE_NEW_MPEGTS_OUTPUT=OFF`，按交付配置黑名单部分插件，CPack 包名 `obs-studio-baseline`，运行时安装前缀 `/usr/local/ans`（桌面集成文件位于 `/usr/share`），Depends 四个依赖 deb。最终 builder 显式选择 Mesa 25.0.7 的 GLVND vendor、DRI 和 GBM 路径，Qt 阶段保持 GLES-only 洁净。

## 项目结构

| 文件/目录 | 作用 |
| --- | --- |
| `Dockerfile` | 多阶段：base → mesa25 / qt6 / mpp / ffmpeg6（依赖编译 + 打 deb，统一 prefix `/usr/local/ans`）→ obs-builder（开发镜像） |
| `mesa25-run` / `mesa-egl-gles-smoke.c` | 固定 Mesa 运行环境和验证 EGL 初始化、GLES 清屏、像素读回 |
| `build-obs.sh` | 容器入口，`docker run` 时自动编译挂载进来的 OBS 源码 |
| `cmake/cpack-desktop-integration.cmake` | 在 CPack 暂存目录中将菜单、图标和 metainfo 移到标准 XDG 路径 |
| `vendor/rk3588/` | 设备 BSP 同版 librga deb（SHA-256 固定，构建期依赖） |
| `.github/workflows/docker-build.yml` | 原生 arm64 CI：tag 发布 deb/镜像；手动或专用分支构建测试产物 |
