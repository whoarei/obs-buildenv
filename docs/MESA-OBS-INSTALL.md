# Mesa 25 与 OBS 简要安装手册

本文用于在 RK3588、Debian 11 arm64 系统上安装 `obs-buildenv v0.3.0`
产出的 Mesa 25.0.7 和 OBS。详细的 Mesa 构建说明及 EGL/GLES 测试方法分别见
[MESA25-BUILD-PACKAGING.md](MESA25-BUILD-PACKAGING.md) 和
[MESA25-EGL-GLES-TEST.md](MESA25-EGL-GLES-TEST.md)。

## 1. 准备安装包

使用以下 arm64 deb：

```text
mesa25-local_*_arm64.deb
qt6.2-gles-local_*_arm64.deb
rockchip-mpp-local_*_arm64.deb
ffmpeg6.1-ans-local_*_arm64.deb
obs-studio-*-Linux.deb
```

文件名中的 `*` 对应各包的版本号段，随构建版本变化；同一批产物中的版本段
保持一致即可，本文命令均使用 glob 匹配，无需按版本修改。

Mesa、Qt、MPP、FFmpeg 和 OBS 均安装到 `/usr/local/ans`。不要手工删除 Debian
Mesa、GLVND 或 BSP libmali 包；`mesa25-local` 会保留这些包以满足 APT 依赖，
并在安装脚本中安全调整实际加载优先级。

将需要的 deb 放到设备上的同一目录，例如 `/tmp/obs-v0.3.0`，然后进入该目录。
如果随发布包提供了校验文件，先执行：

```sh
sha256sum -c SHA256SUMS
```

## 2. 只安装 Mesa 25

建议先通过 SSH 登录设备。模拟安装不会修改系统：

```sh
sudo apt-get -s install ./mesa25-local_*_arm64.deb
```

确认不会删除系统 Mesa、GLVND 或桌面组件后安装：

```sh
sudo apt-get install ./mesa25-local_*_arm64.deb
sudo systemctl restart lightdm
```

重启 LightDM 会结束当前图形桌面会话。也可以直接重启设备，让 Xorg、LightDM
和后续图形程序完整加载 Mesa 25。

该包会完成以下切换：

- 使用 Mesa 25.0.7 Panfrost/Panthor、EGL、GLES、GLX 和 GBM；
- 使用配套的 libdrm 2.4.124；
- 停用不兼容的 BSP G52 libmali loader 配置，但保留厂商 deb；
- 让 LightDM/Xorg 和普通程序优先使用 `/usr/local/ans` 图形栈；
- 使用 `glamor + DRI3 + SWcursor`，并设置 `PageFlip=false`、`ShadowFB=false`；
- 要求使用 Debian 官方 `xserver-xorg-core >= 2:1.20.11-1+deb11u17`，避开 BSP
  定制 `modesetting` 驱动中会损坏窗口复制/暴露恢复的 Rockchip `FlipFB` 路径；
- 使用修复后正常显示的标准 Xorg 光标，不再启动覆盖箭头窗口。

安装时 APT 会同步升级 Debian Xorg。若设备锁定了旧 BSP Xorg，先执行：

```sh
sudo apt-mark unhold xserver-common xserver-xorg-core xserver-xorg-legacy
```

若旧 `xserver-xorg-core-dbgsym`/`xserver-xorg-legacy-dbgsym` 严格依赖
`2:1.20.11-1`，应先移除这两个仅用于调试的符号包。详细根因和对照证据见
[CURSOR-NOT-VISIBLE-ANALYSIS.md](CURSOR-NOT-VISIBLE-ANALYSIS.md)。

## 3. 安装 Mesa 和 OBS

如果设备尚未安装配套依赖，一次性交给 APT 处理本地 deb 和系统依赖：

```sh
sudo apt-get install \
  ./mesa25-local_*_arm64.deb \
  ./rockchip-mpp-local_*_arm64.deb \
  ./ffmpeg6.1-ans-local_*_arm64.deb \
  ./qt6.2-gles-local_*_arm64.deb \
  ./obs-studio-*-Linux.deb
```

设备 BSP 还需提供 `librga2`。如果它尚未安装，应先安装与当前系统 BSP 匹配的
`librga2` deb，再执行上述命令。

安装完成后重启图形会话：

```sh
sudo systemctl restart lightdm
```

从桌面菜单启动 OBS，或从终端显式使用 Mesa 25 环境启动：

```sh
/usr/bin/env PAN_MESA_DEBUG=gl3 \
  /usr/local/ans/bin/mesa25-run /usr/local/ans/bin/obs
```

桌面入口已经包含同一个 `PAN_MESA_DEBUG=gl3`。这是 Panfrost 的 Mesa 官方实验开关，
用于公开 OBS 所需的桌面 OpenGL 3.3；不要改成 `MESA_GL_VERSION_OVERRIDE` 伪装版本。

重复执行同一条 `apt-get install ./...deb` 命令即可升级或重新安装。APT 会保留
OBS 配置；用户配置通常位于 `~/.config/obs-studio/`。

## 4. 简单确认安装状态

这一步只确认软件包和服务状态，不代替 EGL/GLES 或 OBS 功能验收：

```sh
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  mesa25-local qt6.2-gles-local rockchip-mpp-local ffmpeg6.1-ans-local

dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  xserver-common xserver-xorg-core xserver-xorg-legacy

dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  obs-studio

systemctl is-active lightdm
```

确认当前 X11/OBS 确实使用硬件而不是 `softpipe`：

```sh
DISPLAY=:0 XAUTHORITY=/home/ans/.Xauthority \
  /usr/local/ans/bin/mesa25-run glxinfo -B \
  | grep -E 'direct rendering|Device:|Accelerated:|OpenGL renderer'

grep -E 'glamor X acceleration enabled|Initializing extension DRI3|FlipFB' \
  /var/log/Xorg.0.log

grep -E 'OBS 32|Loading up OpenGL|MP: Using|Startup complete' \
  "$(ls -1t /home/ans/.config/obs-studio/logs/*.txt | head -1)"
```

正确结果应包含 Xorg `2:1.20.11-1+deb11u17` 或更新版本、
`Mali-G610 (Panfrost)`、`Accelerated: yes`、Xorg 的
`glamor X acceleration enabled`/`DRI3`，并且不能包含 `FlipFB`。OBS 应包含：

```text
Loading up OpenGL on adapter Mesa Mali-G610 (Panfrost)
MP: Using hardware video decoder 'h264_rkmpp'
==== Startup complete ===============================================
```

RKMPP 还必须通过进程句柄确认：

```sh
PID=$(pgrep -n -u ans -x obs)
ls -l /proc/$PID/fd | grep /dev/mpp_service
ps -T -p "$PID" -o comm= | grep '^av:h264' || true
```

每个活动 H.264 硬解媒体源通常对应一个 `/dev/mpp_service` 句柄；硬解状态下不应
出现 `av:h264:df*` 软件帧线程。取消“使用硬件解码”后，应看到
`MP: Using software video decoder 'h264'`、MPP 句柄归零并出现软件解码线程。

还应由现场人员确认标准光标可见且移动顺滑，文件管理器在移动、缩放、最小化恢复
和遮挡暴露后没有黑块、彩色扫描线或内容残影，panel 显示正常。

## 5. 卸载与回滚

先用 `dpkg-query` 确认已安装的 OBS 包名，然后只卸载 OBS、继续保留 Mesa 25：

```sh
sudo apt-get remove obs-studio
```

旧版 `obs-studio-baseline` 和实验版 `obs-studio-gles` 会由正式 `obs-studio` 包
自动冲突并替换，不能并存。

彻底回到安装前的系统图形栈，应先卸载依赖 Mesa 25 的 OBS，再卸载 Mesa：

```sh
sudo apt-get remove obs-studio mesa25-local
sudo systemctl restart lightdm
```

卸载 `mesa25-local` 时，维护脚本会撤销 `dpkg-divert`、恢复 BSP libmali loader
并更新动态链接缓存。包内 Xorg 配置随包删除；设备原 `20-modesetting.conf`
从未被改动。原有 Debian Mesa、GLVND 和厂商包也从未被删除。
