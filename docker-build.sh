#!/bin/sh
# 构建 obs-builder:debian11-arm64 镜像，并导出 Mesa / Qt6 / MPP / FFmpeg deb 到 ./out/
# 用法：./docker-build.sh
# 全量构建只在里程碑验收时执行；日常修复走 README 中的 docker run 热循环。
set -e
cd "$(dirname "$0")"
export DOCKER_BUILDKIT=1

MESA_SOURCE=${MESA_SOURCE:-../mesa-25.0.7}
test -f "$MESA_SOURCE/VERSION" || {
    echo "Mesa 源码未找到：$MESA_SOURCE" >&2
    exit 1
}
test "$(cat "$MESA_SOURCE/VERSION")" = 25.0.7 || {
    echo "Mesa 源码版本不是 25.0.7：$MESA_SOURCE/VERSION" >&2
    exit 1
}

docker build --platform=linux/arm64 --build-context "mesa_source=$MESA_SOURCE" \
    --target debs --output "type=local,dest=$PWD/out" .
docker build --platform=linux/arm64 --build-context "mesa_source=$MESA_SOURCE" \
    --target obs-builder -t obs-builder:debian11-arm64 .

echo
echo "== 镜像 =="
docker images obs-builder:debian11-arm64
echo "== deb 产物（./out/） =="
find out -name "*.deb" -o -name SHA256SUMS | sort
