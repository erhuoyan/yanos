#!/bin/bash
# release.sh — YanOS 一键构建发布
# 在 VPS 上运行，拉取最新代码，构建 ISO，上传到对象存储
#
# 用法:
#   ./hack/yanos/release.sh v1.13.4-yanos.1           # 指定 tag 发布
#   ./hack/yanos/release.sh v1.13.4-yanos.1 --skip-iso  # 只构建 yanctl
#   ARCH=arm64 ./hack/yanos/release.sh v1.13.4-yanos.1   # arm64 ISO
set -euo pipefail

# --- 参数 ---
TAG="${1:?用法: $0 <tag> [--skip-iso]}"
SKIP_ISO="${2:-}"
ARCH="${ARCH:-amd64}"

# --- 配置 ---
REGISTRY="hub-vpc.jdcloud.com"
IMAGER_REPO="iaas-jf/siderolabs/imager"
# 从 yanos tag 中提取上游版本: v1.13.4-yanos.1 → v1.13.4
UPSTREAM_VERSION="${TAG%%-yanos*}"
IMAGER_TAG="${UPSTREAM_VERSION}"

OSS_ALIAS="yxh-oss"
OSS_BUCKET="gengyan15"
OSS_PATH="yanos/releases/${TAG}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${REPO_DIR}/_out"

export PATH=/usr/local/go/bin:/usr/local/bin:$PATH

# --- 函数 ---
info() { echo -e "\033[36m>>>\033[0m $*"; }
err()  { echo -e "\033[31mERR\033[0m $*" >&2; exit 1; }

# --- 主流程 ---
cd "${REPO_DIR}"

info "同步代码..."
git fetch --tags
git checkout main
git pull

info "注入 gendata (tag=${TAG})..."
mkdir -p pkg/machinery/gendata/data
echo -n "YanOS"          > pkg/machinery/gendata/data/name
echo -n "${TAG}"         > pkg/machinery/gendata/data/tag
echo -n "$(git rev-parse --short=8 HEAD)" > pkg/machinery/gendata/data/sha
echo -n "erhuoyan"       > pkg/machinery/gendata/data/username
echo -n "${REGISTRY}"    > pkg/machinery/gendata/data/registry

info "构建 yanctl (linux/${ARCH})..."
mkdir -p "${OUTPUT_DIR}"
CGO_ENABLED=0 GOOS=linux GOARCH="${ARCH}" \
  go build -tags grpcnotrace -ldflags "-s -w" \
  -o "${OUTPUT_DIR}/yanctl-linux-${ARCH}" ./cmd/yanctl

info "yanctl 版本:"
"${OUTPUT_DIR}/yanctl-linux-${ARCH}" version --client 2>&1 | grep -E "Tag|SHA" || true

if [ "${SKIP_ISO}" = "--skip-iso" ]; then
  info "跳过 ISO 构建"
else
  IMAGER_IMAGE="${REGISTRY}/${IMAGER_REPO}:${IMAGER_TAG}"
  info "拉取 imager: ${IMAGER_IMAGE}"
  docker pull "${IMAGER_IMAGE}"

  info "生成 ISO (${ARCH})..."
  docker run --rm -t \
    -v "${OUTPUT_DIR}:/out" \
    "${IMAGER_IMAGE}" \
    metal --arch "${ARCH}" --output-kind iso

  # 重命名 ISO 带上 tag
  if [ -f "${OUTPUT_DIR}/metal-${ARCH}.iso" ]; then
    mv "${OUTPUT_DIR}/metal-${ARCH}.iso" "${OUTPUT_DIR}/yanos-${TAG}-${ARCH}.iso"
    info "ISO: ${OUTPUT_DIR}/yanos-${TAG}-${ARCH}.iso"
  fi
fi

info "生成 sha256sum..."
cd "${OUTPUT_DIR}"
sha256sum yanctl-linux-${ARCH} yanos-${TAG}-${ARCH}.iso 2>/dev/null > sha256sum-${TAG}.txt || \
sha256sum yanctl-linux-${ARCH} > sha256sum-${TAG}.txt

info "上传到对象存储: ${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"
mc cp "${OUTPUT_DIR}/yanctl-linux-${ARCH}" "${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"
mc cp "${OUTPUT_DIR}/sha256sum-${TAG}.txt" "${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"
if [ -f "${OUTPUT_DIR}/yanos-${TAG}-${ARCH}.iso" ]; then
  mc cp "${OUTPUT_DIR}/yanos-${TAG}-${ARCH}.iso" "${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"
fi

info "上传完成! 文件列表:"
mc ls "${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"

echo ""
echo "=== 发布完成 ==="
echo "Tag:     ${TAG}"
echo "OSS:     ${OSS_ALIAS}/${OSS_BUCKET}/${OSS_PATH}/"
echo "yanctl:  yanctl-linux-${ARCH}"
[ -f "${OUTPUT_DIR}/yanos-${TAG}-${ARCH}.iso" ] && echo "ISO:     yanos-${TAG}-${ARCH}.iso"
