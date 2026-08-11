# OBS 32.2.1 RK3588 GLES / RKMPP 测试指南

本文用于验证 `rk3588/32.2.1-gles` 分支在 RK3588 Debian 11 arm64 设备上的以下能力：

- OBS 使用 Mali GPU 的 OpenGL ES 3.2 渲染后端，而不是 desktop OpenGL/GLX。
- 媒体源勾选“硬件解码”后，实际选择 FFmpeg Rockchip 的 `*_rkmpp` 解码器。
- RKMPP 不可用或关闭硬解时，可以回退到 FFmpeg 软件解码器。
- 双媒体源、循环播放、录制及录制文件完整解码正常。
- 测试结束后恢复用户配置，并留下明确、可复核的测试结果。

本文命令默认从 `obs-buildenv/` 目录执行。测试设备示例为 `172.16.0.154`，运行桌面的用户为 `linaro`。不要把设备密码、私钥、原始设备日志或用户媒体文件提交到仓库。

## 1. 测试前准备

本机设置以下变量。SSH 使用密钥或交互式密码认证，不要把密码写入脚本或文档。

```sh
export TEST_HOST=root@172.16.0.154

export REPO=$(realpath ../obs-studio)
export SRC=$REPO/.worktrees/obs32-gles
```

确认源码来自指定分支，工作树没有未提交修改：

```sh
git -C "$SRC" status --short --branch
git -C "$SRC" branch --show-current
git -C "$SRC" log -3 --oneline
git -C "$SRC" diff --check
```

预期分支：

```text
rk3588/32.2.1-gles
```

确认设备图形会话可用：

```sh
ssh "$TEST_HOST" 'systemctl is-active lightdm'
ssh "$TEST_HOST" \
  'timeout 5 runuser -u linaro -- env DISPLAY=:0 XAUTHORITY=/home/linaro/.Xauthority xdpyinfo 2>&1 | grep -m1 dimensions'
```

验收标准：

- LightDM 为 `active`。
- `xdpyinfo` 在 5 秒内返回分辨率。

如果 LightDM 显示 active，但 `xdpyinfo` 超时，说明整个 X 会话没有响应，不能把它归因于 OBS 或 RKMPP。确认设备当前没有其他图形任务后，可重启图形会话：

```sh
ssh "$TEST_HOST" 'systemctl restart lightdm'
```

这会结束当前桌面登录会话，但不会重启设备。

## 2. 构建正式 GLES 包

使用与交付一致的容器参数构建，必须同时关闭 desktop OpenGL、开启 GLES：

```sh
docker run --rm \
  --platform linux/arm64 \
  -v "$REPO:$REPO:ro" \
  -e OBS_SRC_DIR="$SRC" \
  -v "$PWD/obs-binary-gles:/output" \
  -v obs32-gles-build:/build \
  -v ccache:/root/.cache/ccache \
  -e EXTRA_CMAKE_FLAGS='-DENABLE_OPENGL=OFF -DENABLE_GLES=ON' \
  -e DEBIAN_PACKAGE_NAME=obs-studio-gles \
  -e OUTPUT_UID=$(id -u) \
  -e OUTPUT_GID=$(id -g) \
  ghcr.io/whoarei/obs-buildenv:latest
```

`obs-builder` 镜像已经内置仓库中的 `build-obs.sh` 和 `cmake/` 辅助脚本。更新这些文件后必须重新构建或发布镜像；只有使用旧镜像临时验证时，才按 README 的兼容方式额外挂载覆盖。

根据当前提交选择无 `-modified` 后缀的正式包：

```sh
HEAD=$(git -C "$SRC" rev-parse --short=9 HEAD)
PACKAGE=$(find obs-binary-gles -maxdepth 1 -type f \
  -name "obs-studio-*-g${HEAD}-Linux.deb" -print -quit)

test -n "$PACKAGE"
sha256sum "$PACKAGE"
dpkg-deb -f "$PACKAGE" Package Version Architecture Depends
```

验收标准：

- `Package` 为 `obs-studio-gles`。
- `Architecture` 为 `arm64`。
- 版本包含当前 Git 短提交号。
- 包名不含 `modified`。
- 构建日志显示 `OpenGL ES renderer`。

保存包的完整文件名、版本和 SHA-256，写入测试记录。

## 3. 准备测试场景

建议使用名为 `s1` 的场景集合，至少包含两个开启循环的本地媒体源：

| 媒体源 | 推荐编码 | 用途 |
| --- | --- | --- |
| 媒体源 1 | H.264 + AAC | 验证 `h264_rkmpp` 和 H.264 软件回退 |
| 媒体源 2 | MPEG-4 Part 2 + AAC | 验证按 codec ID 选择 `mpeg4_rkmpp` |

设备上的场景文件默认位于：

```text
/home/linaro/.config/obs-studio/basic/scenes/s1.json
```

检查媒体路径、循环和硬解配置：

```sh
ssh "$TEST_HOST" \
  'grep -n -E "local_file|hw_decode|looping" /home/linaro/.config/obs-studio/basic/scenes/s1.json'
```

硬解测试开始前，两个源都应为：

```json
"hw_decode": true,
"looping": true
```

使用设备自带的 FFmpeg 检查素材编码、分辨率、帧率和时长：

```sh
ssh "$TEST_HOST" \
  '/usr/local/ans/bin/ffprobe -v error \
   -show_entries stream=index,codec_name,width,height,avg_frame_rate \
   -show_entries format=duration \
   -of compact=p=0:nk=0 "/path/to/media.mp4"'
```

## 4. 停止旧 OBS 和处理异常退出标记

安装前先结束旧进程：

```sh
ssh "$TEST_HOST" '
  PID=$(pgrep -n -u linaro -x obs || true)
  if [ -n "$PID" ]; then
    kill -TERM "$PID"
    n=0
    while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 10 ]; do
      sleep 1
      n=$((n + 1))
    done
    kill -KILL "$PID" 2>/dev/null || true
  fi
'
```

注意：OBS 未主动退出时，可能只是弹出了“是否退出”或“是否停止活动输出”的确认框，不应直接判断为死锁或崩溃。

强制退出会留下 `.sentinel/run_*`。下次启动时 OBS 会停在“正常模式/安全模式”对话框。测试自动启动前，将旧标记移动到 `/tmp` 备份，不要直接删除：

```sh
ssh "$TEST_HOST" '
  BACKUP=/tmp/obs-sentinel-backup-$(date +%s)
  mkdir -p "$BACKUP"
  find /home/linaro/.config/obs-studio/.sentinel \
    -maxdepth 1 -type f -name "run_*" \
    -exec mv -t "$BACKUP" {} + 2>/dev/null || true
'
```

OBS 32.2.1 没有 `--disable-shutdown-check` 参数，不要依赖该参数跳过对话框。

## 5. 安装测试包

复制并安装：

```sh
scp "$PACKAGE" "$TEST_HOST:/tmp/obs-under-test.deb"

ssh "$TEST_HOST" '
  dpkg -i /tmp/obs-under-test.deb
  dpkg-query -W obs-studio-gles
  sha256sum /tmp/obs-under-test.deb
'
```

如果分支做过 squash/rebase，Git 提交计数可能变小，`dpkg` 会显示“降级”。这不一定表示源码更旧，应以包内版本的提交号、当前分支 HEAD 和 SHA-256 为准。

## 6. 启动 OBS

以桌面用户启动，不要用 root 直接运行 GUI：

```sh
ssh "$TEST_HOST" '
  runuser -u linaro -- env \
    HOME=/home/linaro \
    USER=linaro \
    DISPLAY=:0 \
    XAUTHORITY=/home/linaro/.Xauthority \
    XDG_RUNTIME_DIR=/run/user/1000 \
    setsid /usr/local/ans/bin/obs --collection s1 \
    >/tmp/obs-test.stdout 2>&1 </dev/null &
'
```

等待约 15 秒后取得 PID 和最新日志：

```sh
ssh "$TEST_HOST" '
  PID=$(pgrep -n -u linaro -x obs)
  LOG=$(ls -1t /home/linaro/.config/obs-studio/logs/*.txt | head -1)
  echo "PID=$PID"
  echo "LOG=$LOG"
  ps -p "$PID" -o user,pid,ppid,stat,etime,pcpu,pmem,args
'
```

## 7. GLES 渲染验收

```sh
ssh "$TEST_HOST" '
  LOG=$(ls -1t /home/linaro/.config/obs-studio/logs/*.txt | head -1)
  grep -E "OBS [0-9]|Initializing EGL|OpenGL ES loaded|adapter" "$LOG"
'
```

验收标准：

- 日志版本与刚安装的包一致。
- 日志包含 `Initializing EGL/OpenGL ES`。
- 适配器为 `ARM Mali-G610`。
- 日志包含 `OpenGL ES 3.2` 和 `GLSL ES 3.20`。
- OBS 主界面和预览正常显示。

## 8. RKMPP 硬解验收

查看解码器日志：

```sh
ssh "$TEST_HOST" '
  LOG=$(ls -1t /home/linaro/.config/obs-studio/logs/*.txt | head -1)
  grep -E "is_hw_decoding|MP: Using|MP: Failed" "$LOG"
'
```

查看设备句柄和线程：

```sh
ssh "$TEST_HOST" '
  PID=$(pgrep -n -u linaro -x obs)
  echo "mpp_fds=$(ls -l /proc/$PID/fd | grep -c /dev/mpp_service)"
  echo "software_av_threads=$(ps -T -p $PID -o comm | grep -c av: || true)"
  ls -l /proc/$PID/fd | grep -E "mpp_service|dma_heap|dmabuf" || true
  ps -T -p "$PID" -o tid,stat,pcpu,comm | grep -E "mp_media|av:|obs|TID"
'
```

双源场景的验收标准：

- 日志包含 `MP: Using hardware video decoder 'h264_rkmpp'`。
- 日志包含 `MP: Using hardware video decoder 'mpeg4_rkmpp'`。
- OBS 至少打开两个 `/dev/mpp_service` 句柄。
- 不存在 `av:h264:df*` 软件帧线程。
- 两个媒体源均有动态画面，声音和时间进度正常。

`is_hw_decoding: yes` 只表示用户勾选了硬解选项，不能单独证明实际使用硬解。必须同时检查实际解码器名称、`/dev/mpp_service` 和软件帧线程。

`/dev/rga` 没有被打开不代表 RKMPP 解码失败；当前路径主要依赖 `/dev/mpp_service`，RGA 是否参与取决于像素格式和转换路径。

## 9. 循环、重启和拖动测试

1. 让两个媒体源运行超过各自完整时长，至少跨过一次循环边界。
2. 在 OBS 中对两个媒体源分别执行“重新开始”。
3. 将播放位置拖到中间、接近结尾和开头。
4. 每次操作后确认画面继续更新，音画时间没有长期停滞。
5. 再次检查 MPP 句柄和软件解码线程。

验收标准：循环、重新开始和拖动后仍使用 `*_rkmpp`，没有自动退回软件解码，也没有媒体源黑屏。

## 10. 软件回退测试

可以在 OBS 属性界面取消两个媒体源的“使用硬件解码”，也可以在 OBS 完全停止后临时修改场景文件。命令方式必须先备份：

```sh
ssh "$TEST_HOST" '
  SCENE=/home/linaro/.config/obs-studio/basic/scenes/s1.json
  cp -p "$SCENE" /tmp/obs-s1-before-software-test.json
  sed -i "s/\"hw_decode\": true/\"hw_decode\": false/g" "$SCENE"
  chown linaro:linaro "$SCENE"
  grep -o "\"hw_decode\": [a-z]*" "$SCENE"
'
```

重新启动 OBS，按第 8 节检查。验收标准：

- 日志显示 `MP: Using software video decoder 'h264'`。
- 日志显示 `MP: Using software video decoder 'mpeg4'`。
- `/dev/mpp_service` 句柄数为 0。
- 出现一个或多个 `av:h264:df*` 软件帧线程；具体数量取决于 CPU 核数和 FFmpeg 配置。
- 两个媒体源仍能播放。

测试完成并停止 OBS 后恢复场景文件：

```sh
ssh "$TEST_HOST" '
  cp -p /tmp/obs-s1-before-software-test.json \
    /home/linaro/.config/obs-studio/basic/scenes/s1.json
  chown linaro:linaro /home/linaro/.config/obs-studio/basic/scenes/s1.json
'
```

恢复后必须确认两个 `hw_decode` 都是 `true`。

## 11. 录制测试

录制测试前恢复硬解场景。为了让自动化 SIGTERM 能正常结束录制，可临时关闭退出确认；必须先备份并在测试后恢复：

```sh
ssh "$TEST_HOST" '
  cp -p /home/linaro/.config/obs-studio/user.ini /tmp/obs-user-before-record-test.ini
  sed -i "s/^ConfirmOnExit=.*/ConfirmOnExit=false/" \
    /home/linaro/.config/obs-studio/user.ini
  chown linaro:linaro /home/linaro/.config/obs-studio/user.ini
'
```

使用 `--startrecording` 启动 OBS：

```sh
ssh "$TEST_HOST" '
  runuser -u linaro -- env \
    HOME=/home/linaro USER=linaro DISPLAY=:0 \
    XAUTHORITY=/home/linaro/.Xauthority \
    XDG_RUNTIME_DIR=/run/user/1000 \
    setsid /usr/local/ans/bin/obs --collection s1 --startrecording \
    >/tmp/obs-record-test.stdout 2>&1 </dev/null &
'
```

至少录制 30 秒。录制期间确认两个 MPP 句柄仍在、软件帧线程为 0。然后发送 SIGTERM 并等待 OBS 正常完成封装：

```sh
ssh "$TEST_HOST" '
  PID=$(pgrep -n -u linaro -x obs)
  kill -TERM "$PID"
  n=0
  while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 20 ]; do
    sleep 1
    n=$((n + 1))
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "OBS did not finish recording cleanly"
    exit 1
  fi
'
```

从最新日志中取得录制文件路径：

```sh
ssh "$TEST_HOST" '
  LOG=$(ls -1t /home/linaro/.config/obs-studio/logs/*.txt | head -1)
  grep -E "Writing Hybrid|Number of fragments|Total frames output|Total drawn frames|memory leaks" "$LOG"
'
```

对日志中 `Writing Hybrid MP4/MOV file` 后面的文件执行检查：

```sh
ssh "$TEST_HOST" '
  FILE="/home/linaro/YYYY-MM-DD HH-MM-SS.mp4"
  /usr/local/ans/bin/ffprobe -v error \
    -show_entries format=duration,size,bit_rate \
    -show_entries stream=index,codec_name,width,height,pix_fmt,avg_frame_rate \
    -of compact=p=0:nk=0 "$FILE"

  /usr/local/ans/bin/ffmpeg -v error -i "$FILE" \
    -map 0:v:0 -map 0:a:0 -f null -
  echo "full_decode_exit=$?"
'
```

验收标准：

- OBS 日志包含 `Recording Start` 和正常停止信息。
- `Total frames output` 大于 0。
- 录制文件包含 H.264 视频和 AAC 音频。
- 分辨率、帧率、时长符合当前 profile。
- 完整音视频解码退出码为 0。
- 日志最终显示 `Number of memory leaks: 0`。

恢复用户设置：

```sh
ssh "$TEST_HOST" '
  cp -p /tmp/obs-user-before-record-test.ini /home/linaro/.config/obs-studio/user.ini
  chown linaro:linaro /home/linaro/.config/obs-studio/user.ini
  grep "^ConfirmOnExit=" /home/linaro/.config/obs-studio/user.ini
'
```

## 12. 最终恢复和长时间运行

最终状态必须满足：

- `s1.json` 中两个媒体源均为 `"hw_decode": true`。
- `user.ini` 中原有 `ConfirmOnExit` 设置已恢复。
- 没有处于活动状态的录制输出。
- OBS 使用正常模式启动，没有停在异常退出对话框。
- 日志显示两个 `*_rkmpp` 解码器。
- 两个 MPP 句柄存在，软件帧线程为 0。

完成一次启动验收后即可停止监控，让 OBS 持续运行。长时间测试建议记录：

- 启动时间和 PID。
- 使用的包版本、Git 提交和 SHA-256。
- 场景集合和媒体文件摘要。
- 发生卡顿、黑屏或退出时的准确时间及当时操作。
- 是否打开了窗口投影、全屏投影或新预览窗口。

不要把包含用户路径、媒体文件名或其他敏感信息的完整设备日志直接提交到仓库；只摘录与问题有关且已脱敏的行。

## 13. 常见现象与判断

| 现象 | 判断与处理 |
| --- | --- |
| `is_hw_decoding: yes`，但有 `av:h264:df*` | 只是勾选了硬解，实际仍可能是软件解码；检查 `MP: Using` 和 MPP 句柄 |
| 日志出现 VAAPI 初始化失败 | RK3588 上没有可用 VAAPI 时属于预期探测失败；最终选择 RKMPP 即可 |
| SIGTERM 后 OBS 仍存在 | 先检查是否有退出/停止输出确认框，不要直接判定死锁 |
| 启动日志只写 `Crash or unclean shutdown detected` | OBS 正等待正常模式/安全模式选择；备份并移走旧 sentinel 后重启 |
| `xdpyinfo` 也超时 | 整个 X 会话无响应，不是单独的 OBS 解码问题 |
| `dpkg` 显示降级 | squash/rebase 后提交计数可能减小；按 Git 提交号和包 SHA-256 判断 |
| 没有 `/dev/rga` 句柄 | 不等于 RKMPP 失败；以 `/dev/mpp_service` 和实际解码器为准 |

## 14. 测试记录模板

```text
日期：
测试人：
OBS 分支：rk3588/32.2.1-gles
Git 提交：
Debian 包：
SHA-256：
设备：
场景集合：

构建：PASS / FAIL
安装：PASS / FAIL
GLES 3.2：PASS / FAIL
H.264 RKMPP：PASS / FAIL
MPEG-4 RKMPP：PASS / FAIL
循环/拖动：PASS / FAIL
软件回退：PASS / FAIL
录制：PASS / FAIL
录制完整解码：PASS / FAIL
配置恢复：PASS / FAIL

问题与备注：
```
