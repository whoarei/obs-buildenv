#!/bin/sh
# 构建 obs-builder:debian11-arm64 镜像，并导出 qt6 / mpp / ffmpeg deb 到 ./out/
# 用法：./docker-build.sh
# 全量构建只在里程碑验收时执行；日常修复走 README 中的 docker run 热循环。
set -e
cd "$(dirname "$0")"
export DOCKER_BUILDKIT=1

docker build --platform=linux/arm64 --target debs --output "type=local,dest=$PWD/out" .
docker build --platform=linux/arm64 --target obs-builder -t obs-builder:debian11-arm64 .

echo
echo "== 镜像 =="
docker images obs-builder:debian11-arm64
echo "== deb 产物（./out/） =="
find out -name "*.deb" -o -name SHA256SUMS | sort
