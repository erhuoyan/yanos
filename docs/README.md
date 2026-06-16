# YanOS 文档

> YanOS — Fork of [Talos Linux](https://github.com/siderolabs/talos), 通用 K8s OS
> org: [erhuoyan](https://github.com/erhuoyan)

## 文档索引

| 文档 | 内容 |
|------|------|
| [yanos-fork-strategy.md](yanos-fork-strategy.md) | 分支模型、上游同步策略、build tag 体系、改造手法 |
| [talos-linux-analysis.md](talos-linux-analysis.md) | Talos 架构深度分析（machined/apid/trustd/COSI/构建系统） |
| [custom-os-optimization.md](custom-os-optimization.md) | 存算分离架构下的内核/CPU/内存/网络优化分析 |
| [custom-os-branding.md](custom-os-branding.md) | 可定制项清单（OS 名称、内核标识、CLI、启动界面等） |
| [custom-k8s-os-design-deprecated.md](custom-k8s-os-design-deprecated.md) | ~~初版方案（kubeasz 模式）~~ 已弃用 |

## 仓库信息

```
仓库:       https://github.com/erhuoyan/yanos
Fork 自:    https://github.com/siderolabs/talos
许可证:     MPL-2.0
go module:  github.com/siderolabs/talos (故意保持，避免 merge 冲突)
```

## 版本策略

**只追踪上游稳定版本**，不跟 alpha/beta/rc。

| 上游版本 | YanOS 版本 | 说明 |
|----------|------------|------|
| `v1.13.4` | `v1.13.4-yanos.1` | 基于上游稳定版 + YanOS 补丁 |
| `v1.14.0` (将来) | `v1.14.0-yanos.1` | 上游发稳定版后再跟进 |

## 分支

| 分支 | 用途 |
|------|------|
| `main` | 品牌改动 + 上游稳定版同步 |
| `release/v1.13` | 基于 v1.13.x 稳定分支（发布用） |
| `profile/kubevirt` | KubeVirt 虚拟化优化 |
| `profile/*` | 未来其他场景 |

## 上游同步

```bash
# 切到上游稳定 tag 开始工作
git fetch upstream
git checkout -b release/v1.13 v1.13.4
git merge main   # 合入品牌改动

# 上游发新 patch 时
git checkout release/v1.13
git merge v1.13.5  # 合入上游修复
```

## 构建与发布

```bash
# 本地构建 yanctl
make -f yanos.mk yanctl

# GitHub Actions 自动发布（推 tag 触发）
git tag v1.13.4-yanos.1
git push origin v1.13.4-yanos.1
# → GitHub Actions 构建 yanctl 多平台二进制 → Draft Release
```

## ISO / 系统镜像

YanOS 当前不独立构建 ISO。使用上游 Talos Image Factory：
- Web UI: https://factory.talos.dev
- 或 `docker run ghcr.io/siderolabs/imager:v1.13.4 iso`

后续自建 Image Factory 时再添加独立 ISO 产出。
