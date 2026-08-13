# libdrm 2.4.124 KMS 屏幕输出测试

本文用于验证 `mesa25-local` 中自编译的 libdrm 2.4.124 能否在 RK3588
Debian 11 上正常驱动 HDMI KMS 扫描输出和 page-flip。EGL/GLES/Panfrost 渲染
测试请另见 [MESA25-EGL-GLES-TEST.md](MESA25-EGL-GLES-TEST.md)。

## 1. 为什么需要独立测试

已有 EGL/GLES 冒烟测试证明 Mesa 25.0.7 能通过 panthor 在 Mali-G610 上完成
硬件渲染，但 surfaceless EGL 不会设置 HDMI mode，也不会把 framebuffer 扫描到
显示器。因此还需要直接测试以下 libdrm/KMS 路径：

```text
打开 /dev/dri/card0
  → 取得 DRM master
  → 枚举 connected connector
  → 选择 HDMI-A-2 和 1920×1080 mode
  → 创建两个 dumb framebuffer
  → drmModeSetCrtc 开始扫描输出
  → drmModePageFlip 持续双缓冲切换
  → 恢复原 CRTC 和桌面
```

本项目提供 [libdrm-kms-screen-test.c](libdrm-kms-screen-test.c) 完成这条验证。

## 2. 测试影响和安全要求

KMS 屏幕测试需要独占 DRM master，因此必须短暂停止 LightDM/Xorg。测试期间：

- HDMI 屏幕会从桌面切换成动态彩条；
- 顶部色块每秒改变颜色；
- 白色竖条会持续横向移动；
- 默认运行 60 秒；
- 测试结束后恢复原 CRTC，再启动 LightDM；
- 应预设 systemd 自动恢复定时器，防止 SSH 中断后桌面不能恢复。

不要在有人使用设备桌面、录制或播放关键内容时执行。

## 3. 在设备上编译测试程序

从编译机上传源码：

```sh
cd /home/xuess/rockchip/daizong/obs/obs-buildenv
scp libdrm-kms-screen-test.c root@172.16.0.205:/tmp/
```

在设备上以 `root` 编译：

```sh
gcc -O2 -Wall -Wextra -Werror \
  -I/usr/local/ans/include \
  -I/usr/local/ans/include/libdrm \
  /tmp/libdrm-kms-screen-test.c \
  -L/usr/local/ans/lib \
  -Wl,-rpath,/usr/local/ans/lib \
  -ldrm -ldl \
  -o /tmp/libdrm-kms-screen-test
```

检查 ELF 和动态依赖：

```sh
readelf -d /tmp/libdrm-kms-screen-test \
  | grep -E 'NEEDED|RUNPATH|RPATH'

ldd -r /tmp/libdrm-kms-screen-test
```

必须看到：

```text
Shared library: [libdrm.so.2]
Library runpath: [/usr/local/ans/lib]
libdrm.so.2 => /usr/local/ans/lib/libdrm.so.2
```

不得出现 `not found` 或 `undefined symbol`。

## 4. 测试前确认 HDMI 和桌面状态

```sh
systemctl is-active lightdm
pgrep -a Xorg
cat /sys/class/drm/card0-HDMI-A-2/status
cat /sys/class/drm/card0-HDMI-A-2/modes | head

readlink -f /usr/local/ans/lib/libdrm.so.2
sha256sum /usr/local/ans/lib/libdrm.so.2.124.0
```

当前已验证文件为：

```text
/usr/local/ans/lib/libdrm.so.2.124.0
SHA-256: 5615e8926b8e3f68d024f5b11bfe42f4cd00a39da743df29eadc33d66bffd2d2
Build ID: d228a30e85e6b7059d363614eb38385eea790a53
```

该 SHA-256 和 Build ID 与最终 Mesa deb 内的 libdrm 文件一致。

## 5. 执行 60 秒屏幕测试

以下命令必须以 `root` 执行。它先设置一个 90 秒后自动启动 LightDM 的保护任务，
再停止桌面并运行 60 秒测试：

```bash
set -u

START="$(date '+%Y-%m-%d %H:%M:%S')"
LOG="/tmp/libdrm-kms-screen-$(date +%Y%m%d-%H%M%S).txt"
RESTORED=0

restore_desktop() {
  if [ "$RESTORED" -eq 0 ]; then
    systemctl start lightdm >/dev/null 2>&1 || true
    chvt 7 >/dev/null 2>&1 || true
    RESTORED=1
  fi
}

trap restore_desktop EXIT INT TERM

systemctl stop mesa25-display-recover.timer \
  mesa25-display-recover.service >/dev/null 2>&1 || true

systemd-run \
  --unit=mesa25-display-recover \
  --on-active=90 \
  --collect \
  /bin/systemctl start lightdm

systemctl stop lightdm

for i in $(seq 1 20); do
  pgrep -x Xorg >/dev/null || break
  sleep 0.2
done

if pgrep -x Xorg >/dev/null; then
  echo 'FAIL: Xorg did not stop'
  exit 1
fi

/tmp/libdrm-kms-screen-test /dev/dri/card0 60 \
  2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}

restore_desktop

for i in $(seq 1 40); do
  systemctl is-active --quiet lightdm && pgrep -x Xorg >/dev/null && break
  sleep 0.5
done

systemctl stop mesa25-display-recover.timer >/dev/null 2>&1 || true

echo '== restored desktop =='
systemctl is-active lightdm
pgrep -a Xorg
cat /sys/class/drm/card0-HDMI-A-2/status
runuser -u ans -- env \
  DISPLAY=:0 \
  XAUTHORITY=/home/ans/.Xauthority \
  xrandr --current \
  | grep -E '^HDMI-2|1920x1080' \
  | head -3

echo '== new kernel errors =='
journalctl -k --since "$START" --no-pager \
  | grep -Ei 'panthor|gpu fault|iommu fault|drm.*(error|fail|timeout)' \
  || echo none

exit "$STATUS"
```

## 6. 通过标准

程序输出必须同时包含：

```text
libdrm_path=/usr/local/ans/lib/libdrm.so.2
drm_master=acquired
connector=HDMI-A-2
mode=1920x1080
scanout=active
progress_seconds=60.0 page_flips=600
elapsed_seconds=60.000
page_flips=600
PASS: KMS scanout and page flips completed
```

同时确认：

- 屏幕连续显示动态彩条 60 秒，而不是黑屏、花屏或静止画面；
- `/sys/kernel/debug/dri/0/clients` 中测试程序的 `master` 为 `y`；
- `/sys/kernel/debug/dri/0/state` 中 HDMI-A-2 绑定 active CRTC；
- framebuffer 为 1920×1080；
- 进程 maps 包含 `/usr/local/ans/lib/libdrm.so.2.124.0`；
- 测试期间没有 page-flip timeout；
- 测试结束后 LightDM/Xorg 恢复；
- HDMI-2 恢复 1920×1080@60；
- 内核没有新增 DRM、IOMMU 或 panthor fault。

## 7. 本次 60 秒测试结果

测试设备：`172.16.0.205`

测试时间：2026-08-12

实际结果：

```text
libdrm: /usr/local/ans/lib/libdrm.so.2.124.0
DRM device: /dev/dri/card0
DRM master: acquired
connector: HDMI-A-2, id=228
mode: 1920×1080, pixel clock 148500 kHz
CRTC: 73, active=1
framebuffer: XR24, 1920×1080
运行时间: 60.000 秒
page-flip: 600 次
程序退出码: 0
内核 DRM/panthor 错误: 无
测试后 LightDM: active
测试后 HDMI-2: 1920×1080@60
```

恢复后的 Xorg 进程 maps 也包含：

```text
/usr/local/ans/lib/libdrm.so.2.124.0
```

这说明不仅专用 KMS 测试程序使用新版 libdrm，恢复后的日常 Xorg 桌面也在新版
libdrm 下正常输出 1920×1080@60。

本地原始证据保存在：

```text
out/device-evidence-mesa25-libdrm-kms-clean-20260812/
```

其中包括汇总报告、程序输出、进程 maps、DRM clients 和完整 KMS state。

## 8. glmark2-es2-drm 在本设备上的限制

本设备的 `glmark2-es2-drm` 存在 native-state 初始化问题：即使停止 Xorg、切换到
真实 Linux VT，并以 root 执行，它仍会在创建 DRM window 前输出：

```text
Error: glwindow has never been initialized, check native-state code
Error: main: Could not initialize canvas
```

因此不能用该二进制在这台 BSP 上判断 KMS 屏幕输出是否正常。专用测试程序直接
调用 libdrm API，已经实际完成 DRM master、mode set、扫描输出和 600 次
page-flip，结论不依赖 glmark2 的 native-state 实现。
