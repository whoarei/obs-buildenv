# obs-buildenv — OBS 构建环境（Debian 11 arm64 / RK3588）

面向 RK3588（Debian 11 arm64）的 OBS 32.2.1 构建环境。上游依赖 Qt、FFmpeg、Rockchip MPP 已预编译成 deb 并发布，容器镜像负责编译 OBS 源码并产出 deb。

镜像与依赖均为 **linux/arm64**；在 x86_64 主机上通过 QEMU 用户态模拟运行。

## 获取依赖 deb（GitHub Release）

每次推送 `v*` tag 会触发 CI：构建镜像、导出三个依赖 deb 并自动发布到对应 tag 的 **Release**。

到 [Releases](https://github.com/whoarei/obs-buildenv/releases) 下载附件：

| 包 | 版本 | 作用 |
| --- | --- | --- |
| `qt6.2-gles-local` | 6.2.4 | Qt 6.2.4（qtbase + qtsvg，`-opengl es2`，无 desktop GL） |
| `rockchip-mpp-local` | 1.3.9 | nyanmisaka/mpp jellyfin-mpp，硬编解码库 |
| `ffmpeg6.1-ans-local` | 6.1.6 | ffmpeg-rockchip 6.1，rkmpp/rkrga 硬编解 |

- 三个包统一安装到 `/usr/local/ans`，与系统 Qt5 / FFmpeg 4.3 共存。
- `ffmpeg6.1-ans-local` 依赖 `rockchip-mpp-local` 与 `librga2`（librga 为设备 BSP 包，目标机通常已自带）。
- 附件含各目录的 `SHA256SUMS`，下载后先校验：
  ```sh
  sha256sum -c qt6/SHA256SUMS mpp/SHA256SUMS ffmpeg/SHA256SUMS
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
- `builddir` 命名卷保存 CMake 构建树，加速增量编译；配置异常时 `docker volume rm builddir` 后重跑即全量重配。
- `ccache` 命名卷缓存编译产物，建议保留以加速反复编译（删除也不影响正确性）。
- 追加 cmake 参数：`-e EXTRA_CMAKE_FLAGS='-DXXX=ON'`（仅首次配置生效）。
- 自定义产物包名：`-e DEBIAN_PACKAGE_NAME=obs-studio-<version>`（默认 `obs-studio-baseline`，编非基线版本时建议覆盖）。
- 镜像内已设 `PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig` 与 `PATH=/usr/local/ans/bin:...`，OBS 的 FindFFmpeg 优先选中自编译 FFmpeg 6.1.6 而非系统 4.3。

产物 `obs-studio-baseline` deb 安装到目标机时，与依赖 deb 一同安装（`dpkg -i qt6.2-gles-local*.deb rockchip-mpp-local*.deb ffmpeg6.1-ans-local*.deb obs-studio-baseline*.deb`）。

## 基线构建配置

默认按上游基线：桌面 OpenGL 渲染后端（不定义 `OBS_USE_GLES`）、`ENABLE_WAYLAND=OFF`（镜像无 wayland 依赖）、`ENABLE_SCRIPTING=OFF`、`ENABLE_NEW_MPEGTS_OUTPUT=OFF`，按交付配置黑名单部分插件，CPack 包名 `obs-studio-baseline`，安装前缀 `/usr/local/ans`，Depends 三个依赖 deb。desktop GL 开发包只装在最终镜像阶段，Qt 阶段保持 GLES-only 洁净。

## 项目结构

| 文件/目录 | 作用 |
| --- | --- |
| `Dockerfile` | 多阶段：base（依赖）→ qt6 / mpp / ffmpeg6（依赖编译 + 打 deb，统一 prefix `/usr/local/ans`）→ obs-builder（开发镜像） |
| `build-obs.sh` | 容器入口，`docker run` 时自动编译挂载进来的 OBS 源码 |
| `vendor/rk3588/` | 设备 BSP 同版 librga deb（SHA-256 固定，构建期依赖） |
| `.github/workflows/docker-build.yml` | CI：tag 触发构建镜像并发布 deb 到 Release |
