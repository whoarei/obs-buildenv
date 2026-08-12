# Mesa 25.0.7 EGL/GLES 安装与复核手册

本文用于在 RK3588 Debian 11 设备上安装 `mesa25-rk3588-local`，并复核
Mesa 25.0.7、EGL、OpenGL ES 和 panthor/Panfrost 硬件渲染是否正常。

本文示例设备为 `172.16.0.205`。安装操作使用 `root`，所有图形测试必须以
普通用户 `ans` 执行。命令中不包含密码。

如果已经直接登录为 `ans`，测试命令可去掉开头的 `runuser -u ans --`；安装、
`ldconfig` 和读取完整系统日志仍应使用 `root`。

## 1. 测试对象和通过标准

本地 deb：

```text
out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb
```

已验证的 SHA-256：

```text
d01f8d25ea7f83479a54e287a837b0a198670f58bd02715e7c045fb25a7ce514
```

主测试同时满足以下条件即为通过：

1. 安装版本为 `25.0.7-2~ans1`，架构为 `arm64`，状态为 `ii`。
2. EGL vendor 为 `Mesa Project`，EGL 版本为 `1.5`。
3. GLES vendor 为 `Mesa`。
4. renderer 为 `Mali-G610 (Panfrost)`，不能是 `llvmpipe` 或其他软件渲染器。
5. GLES 版本包含 `OpenGL ES 3.1 Mesa 25.0.7`。
6. 像素读回结果为 `64,128,191,255`。
7. 最后一行显示 `PASS`。
8. 动态库检查显示 Mesa EGL、GBM、libdrm 和 Gallium 均从
   `/usr/local/ans/lib` 加载。

## 2. 在编译机校验并上传 deb

在编译机执行：

```sh
cd /home/xuess/rockchip/daizong/obs/obs-buildenv

(cd out/mesa && sha256sum -c SHA256SUMS)

dpkg-deb -f \
  out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb \
  Package Version Architecture Installed-Size

scp out/mesa/mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb \
  root@172.16.0.205:/tmp/
```

校验应输出：

```text
mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb: OK
Package: mesa25-rk3588-local
Version: 25.0.7-2~ans1
Architecture: arm64
```

## 3. 在设备上校验并安装

SSH 登录设备并切换为 `root`，然后执行：

```sh
cd /tmp

echo 'd01f8d25ea7f83479a54e287a837b0a198670f58bd02715e7c045fb25a7ce514  mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb' \
  | sha256sum -c -

dpkg -i ./mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb
ldconfig

dpkg-query -W \
  -f='${Package} ${Version} ${Architecture} status=${db:Status-Abbrev}\n' \
  mesa25-rk3588-local
```

正确结果为：

```text
mesa25-rk3588-local_25.0.7-2~ans1 arm64 status=ii
```

## 4. 检查测试用户和 GPU 驱动

执行：

```sh
id ans
ls -l /dev/dri

for node in /sys/class/drm/renderD*/device/driver; do
  printf '%s -> ' "$node"
  readlink -f "$node"
done

readlink -f /usr/local/ans/lib/dri/panthor_dri.so
```

需要确认：

- `ans` 属于 `video` 和 `render` 组。
- `/dev/dri/renderD*` 至少有一个节点允许 `render` 组读写。
- RK3588 GPU render node 的驱动链接指向
  `/sys/bus/platform/drivers/panthor`。在当前测试设备上是
  `/dev/dri/renderD130`。
- `panthor_dri.so` 最终指向
  `/usr/local/ans/lib/dri/libdril_dri.so`。这是 Mesa megadriver 的正常布局。

## 5. 主验收：EGL/GLES 硬件清屏和像素读回

直接执行以下命令，不需要手工设置 EGL 或动态库环境变量：

```sh
runuser -u ans -- \
  /usr/local/ans/bin/mesa25-run \
  /usr/local/ans/bin/mesa-egl-gles-smoke
```

已验证的正确输出为：

```text
EGL 1.5 vendor=Mesa Project version=1.5
GLES vendor=Mesa renderer=Mali-G610 (Panfrost) version=OpenGL ES 3.1 Mesa 25.0.7
pixel=64,128,191,255
PASS: EGL initialized and GLES rendered/read back the expected pixel
```

这个测试不是只查询版本字符串。它会创建 EGL surfaceless display、EGL pbuffer
和 GLES 2 context，使用 GLES 清屏，再通过 `glReadPixels` 读回像素并核对颜色。
renderer 为 `Mali-G610 (Panfrost)` 说明实际使用了 RK3588 GPU。

必须通过 `mesa25-run` 启动。部分 RK3588 BSP 会让厂商 Mali
`libEGL.so.1` 在动态链接缓存中排到 GLVND 前面；直接运行测试程序可能绕过
Mesa，出现 `EGL_BAD_PARAMETER (0x300c)`。

## 6. 复核 Mesa 实际加载的库

执行：

```sh
LDLOG=/tmp/mesa25-lddebug.txt

runuser -u ans -- env LD_DEBUG=libs \
  /usr/local/ans/bin/mesa25-run \
  /usr/local/ans/bin/mesa-egl-gles-smoke \
  >/tmp/mesa25-smoke.txt 2>"$LDLOG"

cat /tmp/mesa25-smoke.txt

grep -E 'calling init: .*lib(EGL|GLES|drm|gbm|gallium)' "$LDLOG" \
  | tail -30
```

正确加载链应包含：

```text
/usr/lib/aarch64-linux-gnu/libGLESv2.so.2
/usr/lib/aarch64-linux-gnu/libEGL.so.1
/usr/local/ans/lib/libdrm.so.2
/usr/local/ans/lib/libgbm.so.1
/usr/local/ans/lib/libgallium-25.0.7.so
/usr/local/ans/lib/libEGL_mesa.so.0
```

前两项是 Debian 的 GLVND 客户端分发库，出现它们是正确的。真正的 Mesa EGL
vendor、GBM、libdrm 和 Gallium 驱动必须来自 `/usr/local/ans`。

再执行一次 EGL 调试测试，确认 Mesa 选择 panthor：

```sh
runuser -u ans -- env EGL_LOG_LEVEL=debug \
  /usr/local/ans/bin/mesa25-run \
  /usr/local/ans/bin/mesa-egl-gles-smoke \
  >/tmp/mesa25-egl-debug.txt 2>&1

grep -E 'using driver|^EGL |^GLES |^pixel=|^PASS' \
  /tmp/mesa25-egl-debug.txt
```

其中应包含：

```text
libEGL debug: using driver panthor
```

## 7. 一次性生成复核结果文件

下面的命令会把系统信息、安装状态、GPU 节点、主测试结果和动态库加载链汇总
到一个文件中。请在设备上以 `root` 执行：

```bash
REPORT="/tmp/mesa25-egl-gles-$(date +%Y%m%d-%H%M%S).txt"
LDLOG="${REPORT%.txt}-lddebug.txt"
EGLLOG="${REPORT%.txt}-egl-debug.txt"

{
  echo '== time =='
  date -Is

  echo '== system =='
  uname -a

  echo '== package =='
  dpkg-query -W \
    -f='${Package} ${Version} ${Architecture} status=${db:Status-Abbrev}\n' \
    mesa25-rk3588-local

  echo '== ans user =='
  id ans

  echo '== DRM nodes =='
  ls -l /dev/dri
  for node in /sys/class/drm/renderD*/device/driver; do
    printf '%s -> ' "$node"
    readlink -f "$node"
  done

  echo '== DRI driver =='
  readlink -f /usr/local/ans/lib/dri/panthor_dri.so

  echo '== EGL/GLES smoke =='
  runuser -u ans -- \
    /usr/local/ans/bin/mesa25-run \
    /usr/local/ans/bin/mesa-egl-gles-smoke

  echo '== loaded libraries =='
  runuser -u ans -- env LD_DEBUG=libs \
    /usr/local/ans/bin/mesa25-run \
    /usr/local/ans/bin/mesa-egl-gles-smoke \
    >/tmp/mesa25-report-smoke.txt 2>"$LDLOG"
  cat /tmp/mesa25-report-smoke.txt
  grep -E 'calling init: .*lib(EGL|GLES|drm|gbm|gallium)' "$LDLOG" \
    | tail -30

  echo '== Mesa driver selection =='
  runuser -u ans -- env EGL_LOG_LEVEL=debug \
    /usr/local/ans/bin/mesa25-run \
    /usr/local/ans/bin/mesa-egl-gles-smoke \
    >"$EGLLOG" 2>&1
  grep -E 'using driver|^EGL |^GLES |^pixel=|^PASS' "$EGLLOG"
} 2>&1 | tee "$REPORT"

echo "report: $REPORT"
echo "loader detail: $LDLOG"
echo "EGL detail: $EGLLOG"
```

将最后显示的三个文件复制回编译机即可复核或归档。例如：

```sh
scp root@172.16.0.205:/tmp/mesa25-egl-gles-\*.txt ./
```

## 8. 可选：直接 DRM/GBM GLES 测试

设备安装了 `glmark2-es2-drm` 时，可以执行：

```sh
runuser -u ans -- \
  /usr/local/ans/bin/mesa25-run \
  glmark2-es2-drm \
  --benchmark build:duration=2.0 \
  --size 320x240
```

需要确认输出包含：

```text
GL_VENDOR:      Mesa
GL_RENDERER:    Mali-G610 (Panfrost)
GL_VERSION:     OpenGL ES 3.1 Mesa 25.0.7
```

如果图形桌面正在运行，Xorg 已经持有 DRM master，测试可能同时输出：

```text
Failed to become DRM master
```

这是显示设备所有权限制，不代表 EGL/GLES 初始化或 GPU 渲染失败。不要为了这个
可选测试直接停止正在使用的桌面；主验收以第 5 节的清屏和像素读回测试为准。

## 9. 可选：X11 窗口 EGL/GLES 测试

Xorg 的 DRI3/glamor 已正常初始化时，可在桌面会话中执行：

```sh
runuser -u ans -- env \
  DISPLAY=:0 \
  XAUTHORITY=/home/ans/.Xauthority \
  /usr/local/ans/bin/mesa25-run \
  glmark2-es2 \
  --benchmark build:duration=2.0 \
  --size 320x240
```

当前 `172.16.0.205` 的 Xorg 启动日志中已有
`glamor initialization failed`，并且 X11 客户端无法取得 DRI3 device，因此这个
可选测试目前可能报告 `EGL_NOT_INITIALIZED`。这属于 Xorg 启动时的显示栈状态，
不影响第 5 节已经验证通过的 panthor surfaceless EGL/GLES 硬件渲染。

## 10. 常见异常判断

### `FAIL: no EGL display (EGL error 0x300c)`

通常是直接运行了 `mesa-egl-gles-smoke`，加载到 BSP 厂商 Mali EGL，而没有使用
GLVND/Mesa。使用正确命令：

```sh
/usr/local/ans/bin/mesa25-run \
  /usr/local/ans/bin/mesa-egl-gles-smoke
```

### renderer 为 `llvmpipe`

这是软件渲染，不算通过。检查：

- 是否以 `ans` 用户执行；
- `ans` 是否属于 `render` 组；
- `/dev/dri/renderD*` 权限；
- GPU render node 是否绑定 `panthor`；
- 内核日志中是否有 panthor 初始化或 GPU fault 错误。

### X11 测试显示 `DRI3: Could not get DRI3 device`

检查 `/var/log/Xorg.0.log` 中的 `glamor`、`DRI3` 和 `eglInitialize`。这是 Xorg
显示路径问题，应与 surfaceless 主验收结果分开记录。

### `glmark2-es2-drm` 显示无法成为 DRM master

通常是 Xorg/Wayland compositor 正在使用显示设备。只要主验收通过，并且该测试
已显示 Mesa 25.0.7、Mali-G610 (Panfrost)，就不应将 DRM master 提示解释为
GLES 驱动加载失败。

## 11. 本次已验证结果

测试日期：2026-08-12

设备与软件：

```text
设备：172.16.0.205
架构：aarch64
内核：6.1.115
GPU 内核驱动：panthor
包：mesa25-rk3588-local 25.0.7-2~ans1 arm64
测试用户：ans（video、render 组）
```

最终结论：

```text
EGL 1.5 初始化通过
OpenGL ES 3.1 Mesa 25.0.7 初始化通过
Mali-G610 (Panfrost) 硬件渲染通过
清屏及 glReadPixels 像素校验通过：64,128,191,255
Mesa EGL/GBM/libdrm/Gallium 从 /usr/local/ans 加载
```
