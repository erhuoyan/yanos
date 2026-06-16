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

## 分支

| 分支 | 用途 |
|------|------|
| `main` | 品牌改动 + 上游同步 |
| `profile/kubevirt` | KubeVirt 虚拟化优化 |
| `profile/*` | 未来其他场景 |

## 上游同步

```bash
git fetch upstream
git checkout main && git merge upstream/main
git checkout profile/kubevirt && git merge main
```
