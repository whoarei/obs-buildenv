# Mesa 25 与 OBS 简要安装手册

本文用于在 RK3588、Debian 11 arm64 系统上安装 `obs-buildenv v0.2.0`
产出的 Mesa 25.0.7 和 OBS。详细的 Mesa 构建说明及 EGL/GLES 测试方法分别见
[MESA25-BUILD-PACKAGING.md](MESA25-BUILD-PACKAGING.md) 和
[MESA25-EGL-GLES-TEST.md](MESA25-EGL-GLES-TEST.md)。

## 1. 准备安装包

使用以下 arm64 deb：

```text
mesa25-local_25.0.7-8~ans1_arm64.deb
qt6.2-gles-local_6.2.4-1~ans1_arm64.deb
rockchip-mpp-local_1.3.9-1~ans1_arm64.deb
ffmpeg6.1-ans-local_6.1.6-1~ans1_arm64.deb
obs-studio-32.2.1-*-Linux.deb
```

Mesa、Qt、MPP、FFmpeg 和 OBS 均安装到 `/usr/local/ans`。不要手工删除 Debian
Mesa、GLVND 或 BSP libmali 包；`mesa25-local` 会保留这些包以满足 APT 依赖，
并在安装脚本中安全调整实际加载优先级。

将需要的 deb 放到设备上的同一目录，例如 `/tmp/obs-v0.2.0`，然后进入该目录。
如果随发布包提供了校验文件，先执行：

```sh
sha256sum -c SHA256SUMS
```

## 2. 只安装 Mesa 25

建议先通过 SSH 登录设备。模拟安装不会修改系统：

```sh
sudo apt-get -s install ./mesa25-local_25.0.7-8~ans1_arm64.deb
```

确认不会删除系统 Mesa、GLVND 或桌面组件后安装：

```sh
sudo apt-get install ./mesa25-local_25.0.7-8~ans1_arm64.deb
sudo systemctl restart lightdm
```

重启 LightDM 会结束当前图形桌面会话。也可以直接重启设备，让 Xorg、LightDM
和后续图形程序完整加载 Mesa 25。

该包会完成以下切换：

- 使用 Mesa 25.0.7 Panfrost/Panthor、EGL、GLES、GLX 和 GBM；
- 使用配套的 libdrm 2.4.124；
- 停用不兼容的 BSP G52 libmali loader 配置，但保留厂商 deb；
- 让 LightDM/Xorg 和普通程序优先使用 `/usr/local/ans` 图形栈。
- 为避免 Debian 11 Xorg 1.20 glamor 在 RK3588 上丢失鼠标光标，Xorg 服务器使用
  软件 2D/ShadowFB；OBS 及其他 EGL/GLES/GLX 客户端仍由 Panfrost 硬件加速。

## 3. 安装 Mesa 和 OBS

如果设备尚未安装配套依赖，一次性交给 APT 处理本地 deb 和系统依赖：

```sh
sudo apt-get install \
  ./mesa25-local_25.0.7-8~ans1_arm64.deb \
  ./rockchip-mpp-local_1.3.9-1~ans1_arm64.deb \
  ./ffmpeg6.1-ans-local_6.1.6-1~ans1_arm64.deb \
  ./qt6.2-gles-local_6.2.4-1~ans1_arm64.deb \
  ./obs-studio-32.2.1-*-Linux.deb
```

设备 BSP 还需提供 `librga2`。如果它尚未安装，应先安装与当前系统 BSP 匹配的
`librga2` deb，再执行上述命令。

安装完成后重启图形会话：

```sh
sudo systemctl restart lightdm
```

从桌面菜单启动 OBS，或从终端显式使用 Mesa 25 环境启动：

```sh
/usr/local/ans/bin/mesa25-run /usr/local/ans/bin/obs
```

重复执行同一条 `apt-get install ./...deb` 命令即可升级或重新安装。APT 会保留
OBS 配置；用户配置通常位于 `~/.config/obs-studio/`。

## 4. 简单确认安装状态

这一步只确认软件包和服务状态，不代替 EGL/GLES 或 OBS 功能验收：

```sh
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  mesa25-local qt6.2-gles-local rockchip-mpp-local ffmpeg6.1-ans-local

dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
  'obs-studio-*'

systemctl is-active lightdm
```

## 5. 卸载与回滚

先用 `dpkg-query` 确认已安装的 OBS 包名，然后只卸载 OBS、继续保留 Mesa 25：

```sh
sudo apt-get remove obs-studio-gles
```

如果安装的是其他 OBS 包名（例如 `obs-studio-baseline`），请替换上述名称。

彻底回到安装前的系统图形栈，应先卸载依赖 Mesa 25 的 OBS，再卸载 Mesa：

```sh
sudo apt-get remove obs-studio-gles mesa25-local
sudo systemctl restart lightdm
```

卸载 `mesa25-local` 时，维护脚本会撤销 `dpkg-divert`、恢复 BSP libmali loader
并更新动态链接缓存。包内 Xorg 配置随包删除；设备原 `20-modesetting.conf`
从未被改动。原有 Debian Mesa、GLVND 和厂商包也从未被删除。
