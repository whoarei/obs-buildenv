# obs-buildenv — OBS 32.2.1 构建环境（Debian 11 arm64 / RK3588）

本目录是独立的构建环境描述（脱离任何一份 OBS checkout 存在），计划与验收记录见
`../docs/obs-build-environment-plan.md`。

## 组成

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | multi-stage：base（依赖）→ qt6 / mpp / ffmpeg6（独立依赖编译+打 deb，统一 prefix `/usr/local/ans`）→ debs（导出）→ obs-builder（开发镜像） |
| `docker-build.sh` | 全量构建：导出 deb 到 `./out/` 并生成镜像 `obs-builder:debian11-arm64`（仅里程碑验收时执行） |
| `build-obs.sh` | 容器入口：`docker run` 时自动构建挂载进来的 OBS 源码 |
| `vendor/rk3588/` | 设备 BSP 同版 librga deb（2.2.0-1，SHA-256 固定）；librockchip_mpp 由 Dockerfile mpp 阶段自编译并独立打 deb（设备 BSP mpp API 过旧，见计划 §2.2） |
| `device-verify.sh` | 设备验收脚本（mpp F、M2/M3/M4 的 C/D/E 验收项 + 设备状态还原），随 deb 一起 scp 到目标设备执行 |

## 一次性全量构建（里程碑验收）

```sh
./docker-build.sh
```

产出（三个依赖 deb 统一装到 `/usr/local/ans`，与系统包共存）：

- 镜像 `obs-builder:debian11-arm64`（依赖装齐；不含任何 OBS 源码）；
- `out/mpp/rockchip-mpp-local_1.3.9-1~ans1_arm64.deb`（nyanmisaka/mpp jellyfin-mpp
  commit `a9380ef3`，设备 BSP mpp API 过旧无法配对 ffmpeg-rockchip 6.1）；
- `out/qt6/qt6.2-gles-local_6.2.4-1~ans1_arm64.deb`（Qt 6.2.4，`-opengl es2`）；
- `out/ffmpeg/ffmpeg6.1-ans-local_6.1.6-1~ans1_arm64.deb`（nyanmisaka/ffmpeg-rockchip 6.1 分支，
  rkmpp/rkrga 硬编解；Depends `rockchip-mpp-local` + `librga2`，mpp 不随包分发；
  库带 `RUNPATH=/usr/local/ans/lib` 优先于设备系统旧 mpp）。

### 验收方法

1. **构建即验收**：Dockerfile 各阶段内嵌门槛，任一失败即构建失败——
   mpp 阶段校验 `rockchip_mpp.pc` 版本与 `mpp_buffer_sync_partial_end` 符号；
   qt6 阶段 `readelf` 审计 `libQt6Gui.so.6` 无 desktop `libGL`；
   ffmpeg 阶段校验 `ffmpeg`/`ffprobe` 可执行、rkmpp 编解码器注册、
   `ldd -r libavcodec.so.60` 无 `not found`。
2. **产物核对**：`out/` 下三个 deb 各带 `SHA256SUMS`；
   `sha256sum -c out/*/SHA256SUMS` 校验完整，
   `dpkg-deb -I <deb>` 核对 control（Depends / Conflicts），
   `dpkg-deb -c <deb>` 核对文件清单均在 `/usr/local/ans/` 下
   （ffmpeg 包内不得含 `librockchip_mpp`）。
3. **设备验收**（目标 172.16.0.154，详见计划 §6-§9）：把 `out/` 全部 deb 与
   `device-verify.sh` scp 到设备后执行 `./device-verify.sh deps <deb目录>`
   （mpp F0-F2、qt6 C0-C4、ffmpeg D0-D3）；再按下方「日常编译 OBS」产出
   baseline deb 后执行 `./device-verify.sh obs <deb目录>`（E2/E3）；
   验收完毕 `./device-verify.sh restore` 还原设备交付态。

## 日常编译 OBS（热循环）

在任意目录执行（以该目录为执行目录）：

```sh
docker run --rm \
  -v /path/to/obs-studio:/src/obs-studio \
  -v $PWD/obs-binary:/output \
  -v builddir:/build \
  -v ccache:/root/.ccache \
  -e OUTPUT_UID=$(id -u) -e OUTPUT_GID=$(id -g) \
  obs-builder:debian11-arm64
```

容器入口自动完成：在 `/src/obs-studio` 找源码 → cmake 配置（仅首次）→
ninja 编译（首次 `-k 0` 收集全部错误，之后增量 + ccache）→ CPack 出 deb →
deb / ddeb / SHA-256 清单拷贝到 `/output`（即执行目录的 `obs-binary/`）。

- 任意一份 OBS checkout 均可直接拿来编译；镜像不含 OBS 源码快照。
- `builddir` named volume 保存 CMake 构建树（增量加速）；
  构建目录不做 BuildKit cache mount，避免陈旧 CMakeCache 缓存失败的 feature test。
  配置异常时手动清卷：`docker volume rm builddir` 后重跑即全量重配。
- 追加 cmake 参数：`docker run ... -e EXTRA_CMAKE_FLAGS='-DXXX=ON' ...`（仅首次配置生效）。
- 镜像内已设 `PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig` 与
  `PATH=/usr/local/ans/bin:...`，OBS 的 FindFFmpeg 优先选中自编译
  FFmpeg 6.1.6 而非系统 4.3。

## 基线构建配置（M4）

默认按上游基线：桌面 OpenGL 渲染后端（不定义 `OBS_USE_GLES`）、`ENABLE_WAYLAND=OFF`
（镜像无 wayland 依赖，上游默认 ON 会 configure 失败）、`ENABLE_SCRIPTING=OFF`、
`ENABLE_NEW_MPEGTS_OUTPUT=OFF`、交付配置的黑名单插件与 CPack 元数据
（包名 `obs-studio-baseline`，安装前缀 `/usr/local/ans`，
Depends qt6.2-gles-local + ffmpeg6.1-ans-local + rockchip-mpp-local）。
desktop GL 开发包（`libgl1-mesa-dev`/`libglvnd-dev`）只装在 obs-builder 最终阶段，
qt6 阶段保持 GLES-only 洁净。
