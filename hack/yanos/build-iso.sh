#!/bin/bash
# build-iso.sh — 使用内网 imager 镜像生成 ISO
# 前置条件: skopeo copy 已将 imager 镜像传到内网 registry
#
# 用法:
#   ./hack/yanos/build-iso.sh                          # 默认 amd64
#   ARCH=arm64 ./hack/yanos/build-iso.sh               # arm64
#   IMAGER_TAG=v1.13.4 ./hack/yanos/build-iso.sh      # 指定版本
set -euo pipefail

REGISTRY="${REGISTRY:-hub-vpc.jdcloud.com}"
IMAGER_REPO="${IMAGER_REPO:-iaas-jf/siderolabs/imager}"
IMAGER_TAG="${IMAGER_TAG:-v1.13.4}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/_out}"

IMAGER_IMAGE="${REGISTRY}/${IMAGER_REPO}:${IMAGER_TAG}"

echo "=== ISO Builder ==="
echo "Imager:  ${IMAGER_IMAGE}"
echo "Arch:    ${ARCH}"
echo "Output:  ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}"

echo ">>> Pulling imager from internal registry..."
docker pull "${IMAGER_IMAGE}"

echo ">>> Generating ISO..."
docker run --rm -t \
  -v "${OUTPUT_DIR}:/out" \
  "${IMAGER_IMAGE}" \
  metal --arch "${ARCH}" --output-kind iso

echo ""
echo "=== Done ==="
ls -lh "${OUTPUT_DIR}"/metal-*.iso 2>/dev/null || echo "No ISO found - check errors above"
