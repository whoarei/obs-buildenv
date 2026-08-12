# Mesa 25.0.7 编译与 deb 打包说明

本文记录 `mesa25-rk3588-local` 安装到 RK3588 设备之前完成的源码确认、依赖准备、
容器编译、deb 打包和产物检查工作。设备侧的安装及 EGL/GLES 验收步骤见
[MESA25-EGL-GLES-TEST.md](MESA25-EGL-GLES-TEST.md)。

当前构建方式以本地 Docker BuildKit 为准，不需要推送代码或触发 GitHub
workflow。Mesa、Qt、MPP、FFmpeg 和 OBS 继续共用当前 `Dockerfile`；项目没有、
也不需要独立的 `Dockerfile.mesa`。

## 1. 目标与最终产物

构建目标：

- 目标系统：Debian 11 arm64；
- 目标 SoC/GPU：RK3588 / Mali-G610；
- 内核 GPU 驱动：panthor；
- Mesa：25.0.7；
- Gallium 驱动：Panfrost，包含 panthor 用户态支持；
- 图形接口：EGL、OpenGL ES 2/3、GBM；
- 安装前缀：`/usr/local/ans`；
- 输出格式：可用 `dpkg -i` 安装的 arm64 deb。

最终产物：

```text
out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb
```

产物信息：

```text
Package:      mesa25-rk3588-local
Version:      25.0.7-2~ans1
Architecture: arm64
Size:         约 4.2 MB
SHA-256:      d01f8d25ea7f83479a54e287a837b0a198670f58bd02715e7c045fb25a7ce514
```

## 2. 为什么在现有 obs-buildenv 中编译

OBS、Qt、FFmpeg、MPP 和 Mesa 最终都安装到 `/usr/local/ans`，并在同一套 Debian
11 arm64 环境中运行。Mesa 因此被加入现有多阶段 `Dockerfile`，而不是创建一套
独立容器定义。

当前相关阶段为：

```text
base
 └─ mesa-build-base
     └─ mesa25 ──> Mesa deb

base ──> qt6      ──> Qt deb
base ──> mpp      ──> MPP deb
base + mpp ──> ffmpeg6 ──> FFmpeg deb

mesa25 + qt6 + mpp + ffmpeg6 ──> debs / obs-builder
```

这样做有两个直接结果：

- Mesa 专用依赖位于 `mesa-build-base`，不会因为修改 Mesa 配置而主动破坏 Qt、MPP
  或 FFmpeg 阶段的缓存。
- 只验证 Mesa 时可以构建 `mesa25` target，不会构建 Qt、MPP、FFmpeg 或 OBS。

`docker-build.sh` 会构建完整 `debs` 和 `obs-builder`，适合整体里程碑验收；本轮
Mesa 开发和测试不需要执行它。

## 3. 固定的源码和工具版本

为保证可复现，关键输入均固定版本或摘要：

| 输入 | 固定值 |
| --- | --- |
| Debian 基础镜像 | `arm64v8/debian:11@sha256:9690447ddac1819c12c69aca67a003baa947887c504ba6308d19ab8067d148c7` |
| Mesa tag | `mesa-25.0.7` |
| Mesa commit | `742a20f48c59e8649533c84c4d49dd95b403f5da` |
| libdrm | `2.4.124` |
| libdrm SHA-256 | `ac36293f61ca4aafaf4b16a2a7afff312aa4f5c37c9fbd797de9e3c0863ca379` |
| Meson | `1.7.2` |
| Meson wheel SHA-256 | `82c6818dc81743c96de3a458f06175776ebfde4081195ea31ea6971838f25e38` |
| 安装前缀 | `/usr/local/ans` |

Mesa 源码保留在 `obs-buildenv` 仓库之外，通过 BuildKit named context 传入
Dockerfile。这避免把完整 Mesa 源码复制到构建环境仓库。

本地源码树应满足：

```sh
cd /home/xuess/rockchip/daizong/obs/obs-buildenv

test "$(cat ../mesa-25.0.7/VERSION)" = 25.0.7
test "$(git -C ../mesa-25.0.7 rev-parse HEAD)" = \
  742a20f48c59e8649533c84c4d49dd95b403f5da
git -C ../mesa-25.0.7 describe --tags --exact-match
```

预期最后一条命令输出：

```text
mesa-25.0.7
```

如果尚未建立源码 worktree，可从现有 `../mesa` checkout 创建：

```sh
git -C ../mesa worktree add --detach ../mesa-25.0.7 mesa-25.0.7
```

## 4. Debian 11 需要补充的构建依赖

`base` 阶段已经提供编译器、Ninja、pkg-config、ccache、X11/XCB 和通用 OBS
依赖。`mesa-build-base` 在此基础上增加：

```text
python3-pip
python3-mako
python3-yaml
python3-packaging
bison
flex
libexpat1-dev
libglvnd-dev
libxcb-glx0-dev
libxcb-dri2-0-dev
libxcb-dri3-dev
libxcb-present-dev
libxrandr-dev
libxshmfence-dev
libxxf86vm-dev
```

Debian 11 自带 Meson 较旧，因此安装经过 SHA-256 校验的 Meson 1.7.2 wheel。
安装后构建阶段会执行 `meson --version`，版本不等于 `1.7.2` 时立即失败。

## 5. 为什么先编译 libdrm 2.4.124

Debian 11 提供的 `libdrm-dev` 是 2.4.104，而 Mesa 25.0.7 要求至少
libdrm 2.4.109。继续使用系统版本会在 Meson 配置阶段失败，所以 `mesa25`
阶段先编译 libdrm 2.4.124，并安装到同一前缀 `/usr/local/ans`。

libdrm 构建只保留 Mesa/Panfrost 所需的通用 DRM 能力，关闭 Intel、Radeon、
AMDGPU、Nouveau、VMware 等本项目不使用的设备后端、测试和手册。

安装后立即验证：

```sh
PKG_CONFIG_PATH=/usr/local/ans/lib/pkgconfig \
  pkg-config --modversion libdrm
```

必须输出：

```text
2.4.124
```

Mesa 配置时的 `PKG_CONFIG_PATH` 为：

```text
/usr/local/ans/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig
```

因此会优先使用新编译的 libdrm，同时继续使用 Debian 提供的其他开发库。

## 6. Mesa 25.0.7 的编译配置

主要 Meson 配置如下：

| 配置 | 值 | 说明 |
| --- | --- | --- |
| `prefix` | `/usr/local/ans` | 与 Qt、MPP、FFmpeg、OBS 共用前缀 |
| `libdir` | `lib` | 库位于 `/usr/local/ans/lib` |
| `buildtype` | `release` | 发布构建 |
| `platforms` | `x11` | 构建 X11 EGL platform；surfaceless/DRM 仍由 EGL loader 支持 |
| `gallium-drivers` | `panfrost` | Mali-G610/Panfrost，包含 panthor kmod 支持 |
| `egl` | `enabled` | 启用 EGL vendor |
| `gbm` | `enabled` | 启用 GBM 和 DRI GBM backend |
| `gles2` | `enabled` | 启用 GLES 2/3 API |
| `opengl` | `true` | 保留 Mesa OpenGL API 支持 |
| `glx` | `dri` | 构建 DRI GLX vendor |
| `glvnd` | `enabled` | 使用 GLVND 分发 ABI |
| `shared-glapi` | `enabled` | 使用共享 GL API |
| `llvm` | `disabled` | Panfrost 不需要 LLVM，减小依赖和产物 |
| `vulkan-drivers` | 空 | 本包不构建 Vulkan |
| `gallium-va/vdpau/xa` | `disabled` | 视频和 XA 不在本包职责内 |
| `opencl/rusticl` | `disabled` | 不构建 OpenCL |
| `video-codecs` | 空 | 视频编解码由现有 FFmpeg/MPP 栈负责 |
| `build-tests` | `false` | 不把 Mesa 自测套件编入交付包 |
| `tools` | 空 | 不构建额外 Mesa 工具 |
| `osmesa` | `false` | 不构建 OSMesa |

编译器通过 ccache 启动：

```text
CC=ccache gcc
CXX=ccache g++
```

BuildKit 同时把 `/root/.cache/ccache` 作为 cache mount，方便重复构建复用目标文件。

本次完整 Mesa 编译共完成 1260 个 Ninja target。关键生成物包括：

```text
/usr/local/ans/lib/libEGL_mesa.so.0
/usr/local/ans/lib/libGLX_mesa.so.0
/usr/local/ans/lib/libgbm.so.1
/usr/local/ans/lib/gbm/dri_gbm.so
/usr/local/ans/lib/libgallium-25.0.7.so
/usr/local/ans/lib/dri/libdril_dri.so
/usr/local/ans/lib/dri/panfrost_dri.so
/usr/local/ans/lib/dri/panthor_dri.so
/usr/local/ans/lib/dri/rockchip_dri.so
/usr/local/ans/lib/libdrm.so.2.124.0
```

`panfrost_dri.so`、`panthor_dri.so` 和 `rockchip_dri.so` 是指向
`libdril_dri.so` 的 Mesa megadriver 符号链接，这是正常结果。

在 GLVND 模式下，应用链接的 `libEGL.so.1` 和 `libGLESv2.so.2` 由 Debian 的
GLVND 包提供；本包提供的是实际实现渲染功能的 Mesa EGL vendor、Gallium、DRI
和 GBM。因此 deb 声明依赖 `libegl1`、`libgles2` 和 `libglvnd0`。

## 7. 本地只编译 Mesa

在 x86_64 主机上，需要 Docker 已注册 arm64 binfmt/QEMU。可先验证：

```sh
docker run --rm --platform linux/arm64 arm64v8/debian:11 uname -m
```

应输出 `aarch64`。如果系统尚未注册 arm64 binfmt，可执行一次：

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

然后只构建 `mesa25` target：

```sh
cd /home/xuess/rockchip/daizong/obs/obs-buildenv

export DOCKER_BUILDKIT=1

docker build \
  --platform linux/arm64 \
  --build-context mesa_source=../mesa-25.0.7 \
  --target mesa25 \
  -t obs-buildenv:mesa25-local \
  .
```

这条命令不会构建 Qt、MPP、FFmpeg 或 OBS。重复执行时，BuildKit 和 ccache 会
复用没有变化的依赖与编译产物。

不要为了单独验证 Mesa 使用以下 target：

- `debs`：会汇集并触发 Mesa、Qt、MPP、FFmpeg 四条依赖链；
- `obs-builder`：会安装四个依赖 deb 并生成完整 OBS 构建镜像。

## 8. 编译后的自动检查和辅助程序

Mesa 安装完成后，Dockerfile 会先检查以下关键文件必须存在：

```text
panfrost_dri.so
panthor_dri.so
rockchip_dri.so
libEGL_mesa.so.0
libgbm.so.1
libdrm.so.2
```

随后编译项目自带的 `mesa-egl-gles-smoke.c`，生成：

```text
/usr/local/ans/bin/mesa-egl-gles-smoke
```

该程序会在设备上创建 surfaceless EGL display、1×1 pbuffer 和 GLES context，
执行清屏及 `glReadPixels` 像素读回。它属于 deb 的一部分，不需要目标机再安装
编译器。

同时安装启动包装器：

```text
/usr/local/ans/bin/mesa25-run
```

包装器固定：

```text
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/local/ans/share/glvnd/egl_vendor.d/50_mesa.json
LIBGL_DRIVERS_PATH=/usr/local/ans/lib/dri
GBM_BACKENDS_PATH=/usr/local/ans/lib/gbm
LD_LIBRARY_PATH=/usr/local/ans/lib:/usr/lib/aarch64-linux-gnu:...
```

Mesa 的 GLVND vendor JSON 也被改为使用绝对路径：

```json
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "/usr/local/ans/lib/libEGL_mesa.so.0"
  }
}
```

这样不会依赖设备的默认动态库搜索顺序。

## 9. deb 打包过程

打包阶段把 `/usr/local/ans` 下的 libdrm、Mesa 运行库、开发文件、测试程序和
启动包装器复制到包根目录，并加入：

```text
/etc/ld.so.conf.d/00-mesa25-rk3588-local.conf
```

内容为：

```text
/usr/local/ans/lib
```

`postinst` 和 `postrm` 会执行 `ldconfig`，使安装或卸载后动态链接缓存及时更新。

包名不替换 Debian 系统 Mesa 包，文件也不写入 `/usr/lib/aarch64-linux-gnu`。
系统 Mesa、厂商 Mali 库和 `/usr/local/ans` Mesa 可以共存；需要使用 Mesa 25 的
程序通过 `mesa25-run` 启动。

## 10. 从本地镜像导出 deb

构建成功后执行：

```sh
cd /home/xuess/rockchip/daizong/obs/obs-buildenv
mkdir -p out/mesa

docker run --rm \
  --platform linux/arm64 \
  --entrypoint /bin/sh \
  -v "$PWD/out/mesa:/export" \
  obs-buildenv:mesa25-local \
  -c 'cp -a /out/mesa/. /export/'
```

导出内容：

```text
out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb
out/mesa/SHA256SUMS
```

注意：`SHA256SUMS` 内记录的是同目录文件名，因此应进入该目录或使用子 shell
校验：

```sh
(cd out/mesa && sha256sum -c SHA256SUMS)
```

## 11. 安装前的产物检查

检查 control 信息和 SHA-256：

```sh
(cd out/mesa && sha256sum -c SHA256SUMS)

dpkg-deb -I \
  out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb

dpkg-deb -f \
  out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb \
  Package Version Architecture Installed-Size
```

检查关键文件：

```sh
dpkg-deb -c \
  out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb \
  | grep -E '/usr/local/ans/(bin/mesa|lib/(libEGL_mesa|libgbm|libdrm|dri/(panthor|panfrost|rockchip)))'
```

在 arm64 容器中检查动态依赖和未解析符号：

```sh
docker run --rm \
  --platform linux/arm64 \
  --entrypoint /bin/sh \
  obs-buildenv:mesa25-local \
  -c '
    set -e
    export LD_LIBRARY_PATH=/usr/local/ans/lib:/usr/lib/aarch64-linux-gnu
    ldd -r /usr/local/ans/lib/libEGL_mesa.so.0
    ldd -r /usr/local/ans/lib/dri/panthor_dri.so
    ldd -r /usr/local/ans/bin/mesa-egl-gles-smoke
  '
```

`ldd -r` 不应出现 `not found` 或 `undefined symbol`。容器没有 RK3588 GPU，所以
这里仅做 ELF/动态依赖检查；真实 EGL/GLES 渲染必须在设备上完成。

## 12. 编译和设备联调中发现的问题

### 12.1 无效的 Mesa 配置项

第一次配置曾传入：

```text
-Dprecomp-compiler=disabled
```

Mesa 25.0.7 不接受这个取值，Meson 配置因此失败。最终配置删除了该参数，之后
完成全部 1260 个 Ninja target。对应修正提交为 `27c2e96`。

### 12.2 设备优先加载厂商 Mali EGL

第一版 deb 已正确编译 Mesa，但在设备上直接运行测试时得到：

```text
FAIL: no EGL display (EGL error 0x300c)
```

动态链接跟踪证明实际加载的是：

```text
/usr/lib/aarch64-linux-gnu/mali/libEGL.so.1
```

原因是设备 BSP 将厂商 Mali EGL 放在系统 `ld.so.cache` 的 GLVND dispatcher
之前。修正方法不是替换系统库，而是在 `mesa25-run` 中明确指定：

- Debian GLVND 客户端库目录；
- Mesa 25 vendor JSON；
- `/usr/local/ans` 的 DRI、GBM 和运行库目录。

修正后 deb 修订号从 `25.0.7-1~ans1` 提升为 `25.0.7-2~ans1`，避免相同版本号
对应不同内容。最终设备测试成功识别：

```text
EGL 1.5 / Mesa Project
OpenGL ES 3.1 Mesa 25.0.7
Mali-G610 (Panfrost)
panthor
```

对应修正提交为 `3b07537`。

### 12.3 编译器提示

编译过程中出现过 GCC 9 之后结构体参数传递 ABI 变更的 note，以及少量非致命
warning。它们没有造成编译、链接、`ldd -r` 或设备渲染失败，不属于交付阻塞项。

## 13. 与 Qt、MPP、FFmpeg 和 OBS 的关系

Qt 6.2.4、MPP 1.3.9 和 FFmpeg 6.1.6 已有可用 deb，本轮只验证 Mesa 时不需要
重新编译它们。它们仍然与 Mesa 共用 `/usr/local/ans`，完整 `obs-builder` 镜像
需要时才组合四个依赖包。

OBS 打包依赖已经增加：

```text
mesa25-rk3588-local (>= 25.0.7-2~ans1)
```

OBS 的桌面入口也会通过以下命令启动，使 OBS 使用同一套 Mesa 25 环境：

```sh
/usr/local/ans/bin/mesa25-run /usr/local/ans/bin/obs
```

这次为了 Mesa 验证启动过一次完整 `obs-builder` 构建，但确认 Qt 等产物已有后已
主动取消；Mesa deb 的成功编译、打包和设备测试不依赖那次未完成的全量构建。

## 14. 本次工作的可追溯提交

本地分支 `mesa-25.0.7` 上与本工作直接相关的提交：

```text
15a4645 build: add Mesa 25.0.7 RK3588 stack
27c2e96 build: fix Mesa precompiler option
3b07537 fix: select Mesa GLVND stack on RK3588 BSP
4dcf179 docs: add Mesa EGL GLES verification guide
```

根据当前约定，后续构建和测试均在本地进行，不再依赖 GitHub workflow。以上
提交当前只保存在本地分支时，不应为了测试而额外 push。

## 15. 从源码到验收的最短流程

完整流程可以概括为：

```text
校验 Mesa tag/commit
  → 构建 Debian 11 arm64 mesa-build-base
  → 构建并安装 libdrm 2.4.124 到 /usr/local/ans
  → 配置/编译/安装 Mesa 25.0.7 Panfrost
  → 检查 EGL/GBM/DRI/panthor 文件
  → 编译 EGL/GLES 冒烟测试
  → 生成 mesa25-rk3588-local arm64 deb 和 SHA256SUMS
  → 检查 deb control、文件表和 ELF 动态依赖
  → 上传并安装到 RK3588
  → 以 ans 用户执行 EGL/GLES 清屏和像素读回
  → 复核实际加载 /usr/local/ans Mesa 和 panthor 驱动
```

设备安装和结果采集请继续按
[MESA25-EGL-GLES-TEST.md](MESA25-EGL-GLES-TEST.md) 执行。
