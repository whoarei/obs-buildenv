#!/bin/sh
# 构建 OBS builder 镜像，并导出 Mesa / Qt6 / MPP / FFmpeg deb 到 ./out/
# 用法：./docker-build.sh
# 发布构建：IMAGE_TAG=obs-buildenv:v0.2.0 ./docker-build.sh
# Mesa 源码由 Dockerfile 在构建时从官方 archive 下载（SHA256 固定），无需本地准备。
# 全量构建只在里程碑验收时执行；日常修复走 README 中的 docker run 热循环。
set -e
cd "$(dirname "$0")"
export DOCKER_BUILDKIT=1

IMAGE_TAG=${IMAGE_TAG:-obs-builder:debian11-arm64}
OUTPUT_DIR=${OUTPUT_DIR:-$PWD/out}

docker build --platform=linux/arm64 \
    --target debs --output "type=local,dest=$OUTPUT_DIR" .
docker build --platform=linux/arm64 \
    --target obs-builder -t "$IMAGE_TAG" .

echo
echo "== 镜像 =="
docker images "$IMAGE_TAG"
echo "== deb 产物（$OUTPUT_DIR） =="
find "$OUTPUT_DIR" \( -name "*.deb" -o -name SHA256SUMS \) | sort
