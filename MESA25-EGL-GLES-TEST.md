# Mesa 25.0.7 EGL/GLES 安装与复核手册

本文用于在 RK3588 Debian 11 设备上安装 `mesa25-local`，并复核
Mesa 25.0.7、EGL、OpenGL ES 和 panthor/Panfrost 硬件渲染是否正常。

安装之前的源码、依赖、容器编译和 deb 打包过程见
[MESA25-BUILD-PACKAGING.md](MESA25-BUILD-PACKAGING.md)。

本文示例设备为 `172.16.0.205`。安装操作使用 `root`，所有图形测试必须以
普通用户 `ans` 执行。命令中不包含密码。

如果已经直接登录为 `ans`，测试命令可去掉开头的 `runuser -u ans --`；安装、
`ldconfig` 和读取完整系统日志仍应使用 `root`。

## 1. 测试对象和通过标准

本地 deb：

```text
out/mesa/mesa25-local_25.0.7-8~ans1_arm64.deb
```

已验证的 SHA-256：

```text
6d7c524540f7ad5d5b661e4b4d248a48c3ca62e717bf0d2f0e11ce4d26a8baf4
```

主测试同时满足以下条件即为通过：

1. 安装版本为 `25.0.7-8~ans1`，架构为 `arm64`，状态为 `ii`。
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
  out/mesa/mesa25-local_25.0.7-8~ans1_arm64.deb \
  Package Version Architecture Installed-Size

scp out/mesa/mesa25-local_25.0.7-8~ans1_arm64.deb \
  root@172.16.0.205:/tmp/
```

校验应输出：

```text
mesa25-local_25.0.7-8~ans1_arm64.deb: OK
Package: mesa25-local
Version: 25.0.7-8~ans1
Architecture: arm64
```

## 3. 在设备上校验并安装

SSH 登录设备并切换为 `root`，然后执行：

```sh
cd /tmp

(cd /path/to/deb-directory && sha256sum -c SHA256SUMS)

apt-get install ./mesa25-local_25.0.7-8~ans1_arm64.deb
ldconfig

dpkg-query -W \
  -f='${Package} ${Version} ${Architecture} status=${db:Status-Abbrev}\n' \
  mesa25-local
```

正确结果为：

```text
mesa25-local 25.0.7-8~ans1 arm64 status=ii
```

安装前可先执行模拟，输出应只显示旧自定义包 `mesa25-rk3588-local` 被新包替换，
不能删除 Debian Mesa、GLVND 或 BSP libmali：

```sh
apt-get -s install ./mesa25-local_25.0.7-8~ans1_arm64.deb
```

安装后确认这些系统包仍为 `ii`：

```sh
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  mesa25-local libmali-bifrost-g52-g13p0-x11-gbm \
  libegl1 libegl-mesa0 libgbm1 libgl1-mesa-dri
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

最终包已经让 Mesa 25 成为默认栈，直接执行以下命令，不需要包装器或手工环境变量：

```sh
runuser -u ans -- /usr/local/ans/bin/mesa-egl-gles-smoke
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

`mesa25-run` 仍可用于诊断和显式固定加载链，但不再是正常运行的必要条件。
安装脚本通过 dpkg diversion 停用厂商 `00-aarch64-mali.conf`，厂商包与所有
Debian Mesa/GLVND 包仍保持安装状态。

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
    mesa25-local

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

## 8. libdrm/KMS 屏幕扫描输出测试

EGL/GLES 主验收是 surfaceless 硬件渲染，不包含 HDMI mode set 和屏幕扫描输出。
新版 libdrm 2.4.124 的 DRM master、HDMI-A-2 1920×1080 扫描输出和 60 秒
page-flip 已使用专用程序完成验证，步骤及结果见
[LIBDRM-KMS-SCREEN-TEST.md](LIBDRM-KMS-SCREEN-TEST.md)。

当前 BSP 的 `glmark2-es2-drm` 存在 native-state 初始化缺陷，即使释放 Xorg 并
进入真实 Linux VT 也不能创建 DRM window，因此不再将它作为 KMS 验收工具。

## 9. 可选：X11 窗口 EGL/GLES 测试

最终包为保证 RK3588 桌面鼠标光标可见，关闭了 Xorg 服务器自身的 glamor/2D
加速，但 X11 客户端仍可通过 Mesa 25/Panfrost 创建硬件加速的 EGL/GLES/GLX
context。在桌面会话中可执行：

```sh
runuser -u ans -- env \
  DISPLAY=:0 \
  XAUTHORITY=/home/ans/.Xauthority \
  glmark2-es2 \
  --benchmark build:duration=2.0 \
  --size 320x240
```

最终 Xorg 日志应包含：

```text
Option "AccelMethod" "none"
Option "SWcursor" "true"
glamor disabled
ShadowFB: preferred NO, enabled YES
```

`glxinfo -B` 显示 direct rendering、Mesa 25.0.7 和 Mali-G610；
`glmark2-es2` 的 X11 窗口测试也显示 OpenGL ES 3.1 Mesa 25.0.7。

最终包通过 LightDM `xserver-command` 使用 `mesa25-xorg` 包装器，使 Xorg 自身
继承 Mesa 25 的 GLVND、DRI 和 GBM 路径。最终日志应包含：

```text
AIGLX: Loaded and initialized rockchip
GLX: Initialized DRI2 GL provider for screen 0
```

Xorg maps 应只包含 `/usr/local/ans` 的 EGL、GBM、libdrm、Gallium 和
`libdril_dri.so`，不能再出现 `/usr/lib/aarch64-linux-gnu/mali` 或系统
`/usr/lib/aarch64-linux-gnu/dri/swrast_dri.so`。

## 10. 常见异常判断

### `FAIL: no EGL display (EGL error 0x300c)`

旧包上通常表示加载到 BSP 厂商 Mali EGL。最终 `mesa25-local` 安装后，先检查
diversion 和动态链接缓存：

```sh
dpkg-divert --list /etc/ld.so.conf.d/00-aarch64-mali.conf
ldconfig -p | grep -E 'lib(EGL|gbm|drm)\.so'
```

### renderer 为 `llvmpipe`

这是软件渲染，不算通过。检查：

- 是否以 `ans` 用户执行；
- `ans` 是否属于 `render` 组；
- `/dev/dri/renderD*` 权限；
- GPU render node 是否绑定 `panthor`；
- 内核日志中是否有 panthor 初始化或 GPU fault 错误。

### X11 测试显示 `DRI3: Could not get DRI3 device`

最终配置有意关闭 Xorg glamor，因此应优先核对客户端的 EGL/GLX renderer 是否
仍为 `Mali-G610 (Panfrost)`。这是 Xorg 显示路径问题，应与 surfaceless 主验收
结果分开记录。

### `glmark2-es2-drm` 不能创建 DRM window

这是当前 BSP 自带 glmark2 的 native-state 限制，不用于判断新版 libdrm 是否能
输出屏幕。请改用 [LIBDRM-KMS-SCREEN-TEST.md](LIBDRM-KMS-SCREEN-TEST.md)
中的专用测试程序。

## 11. 本次已验证结果

测试日期：2026-08-13

设备与软件：

```text
设备：172.16.0.205
架构：aarch64
内核：6.1.115
GPU 内核驱动：panthor
包：mesa25-local 25.0.7-8~ans1 arm64
测试用户：ans（video、render 组）
```

最终结论：

```text
EGL 1.5 初始化通过
OpenGL ES 3.1 Mesa 25.0.7 初始化通过
Mali-G610 (Panfrost) 硬件渲染通过
清屏及 glReadPixels 像素校验通过：64,128,191,255
Mesa EGL/GBM/libdrm/Gallium 从 /usr/local/ans 加载
Mesa 25 softpipe 软件回退通过
系统 Mesa、GLVND 和 libmali 软件包保持安装
Xorg 使用软件 2D/ShadowFB 兼容路径，鼠标光标正常显示
Xorg AIGLX/GLX rockchip 初始化通过，进程 maps 无系统 Mesa 20/厂商 Mali 混栈
X11 GLX direct rendering 及 glmark2-es2 通过
LightDM/Xorg 60 秒稳定性观察通过：PID 不变，NRestarts=0
```

## 12. 回滚

安装旧自定义 deb 或移除 `mesa25-local` 会触发包的 `postrm`，自动撤销
`dpkg-divert`、恢复厂商 `00-aarch64-mali.conf`，并删除 LightDM drop-in。
包从不修改 BSP 原 `20-modesetting.conf`。测试机上
已用旧包完成过一次实际回滚，LightDM/shadow 显示可以恢复：

```sh
apt-get install ./mesa25-rk3588-local_25.0.7-2~ans1_arm64.deb
systemctl reset-failed lightdm
systemctl restart lightdm
```

厂商 G52 libmali 不能驱动 RK3588 G610，因此这条回滚只恢复原有稳定的软件显示，
不是恢复 GPU 加速。
