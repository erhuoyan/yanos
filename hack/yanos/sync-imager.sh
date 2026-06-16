#!/bin/bash
# sync-imager.sh — 同步上游 imager 镜像到内网 registry
# 在 VPS 上运行，使用 skopeo 从 ghcr.io 加速镜像拷贝到 hub-vpc
#
# 用法:
#   ./hack/yanos/sync-imager.sh v1.13.4          # 同步指定版本
#   ./hack/yanos/sync-imager.sh v1.13.5 v1.14.0  # 同步多个版本
set -euo pipefail

GHCR_MIRROR="${GHCR_MIRROR:-4b8vcjyyxrap3w-ghcr.xuanyuan.run}"
INTERNAL_REGISTRY="hub-vpc.jdcloud.com"
INTERNAL_REPO="iaas-jf/siderolabs/imager"

if [ $# -eq 0 ]; then
  echo "用法: $0 <version> [version...]"
  echo "示例: $0 v1.13.4"
  echo "      $0 v1.13.5 v1.14.0"
  exit 1
fi

for VERSION in "$@"; do
  echo "=== 同步 imager:${VERSION} ==="
  echo "  源:   ${GHCR_MIRROR}/siderolabs/imager:${VERSION}"
  echo "  目标: ${INTERNAL_REGISTRY}/${INTERNAL_REPO}:${VERSION}"
  echo ""

  skopeo copy --override-arch amd64 --override-os linux \
    "docker://${GHCR_MIRROR}/siderolabs/imager:${VERSION}" \
    "docker://${INTERNAL_REGISTRY}/${INTERNAL_REPO}:${VERSION}"

  echo "  ✓ 完成"
  echo ""
done

echo "=== 当前内网 imager 版本 ==="
skopeo list-tags "docker://${INTERNAL_REGISTRY}/${INTERNAL_REPO}" 2>/dev/null | \
  python3 -c 'import sys,json; [print(f"  {t}") for t in json.load(sys.stdin).get("Tags",[])]' || \
  echo "  (无法列出 tags，但镜像已推送)"
