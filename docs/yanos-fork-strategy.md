# YanOS Fork 策略 v2：通用 K8s OS + 场景 Profile

> Fork siderolabs/talos → erhuoyan/yanos
> 定位：通用 K8s OS，KubeVirt 虚拟化是场景之一
> 2026-06-16

---

## 一、分支模型

```
siderolabs/talos (upstream)
  │
  ▼ git fetch upstream
  
erhuoyan/yanos
  │
  ├── main                        ← 只改品牌，1:1 跟上游同步
  │     改动: 品牌常量 + yanctl 入口 + yanos.mk
  │     diff 行数目标: < 200 行
  │
  ├── profile/kubevirt            ← KubeVirt 虚拟化优化
  │     基于 main，增加:
  │     - NUMA/CPU/HugePages 控制器
  │     - 虚拟化内核调优参数
  │     - kubelet topology manager 自动配置
  │
  ├── profile/general             ← 通用 K8s（可能 = main，暂不建）
  │
  ├── profile/edge                ← 未来：边缘计算（暂不建）
  │
  └── release/1.0-kubevirt        ← 发布分支（稳定后建）
```

### 同步流程

```
upstream/main ──merge──→ main ──merge──→ profile/kubevirt
                          │                    │
                     只有品牌改动          品牌 + KubeVirt 优化
                     冲突: 几乎为零        冲突: 极少（新增文件为主）
```

```bash
# 月度同步
git fetch upstream
git checkout main
git merge upstream/main          # 品牌改动跟上游不冲突
git push origin main

git checkout profile/kubevirt
git merge main                   # 把上游更新带入 kubevirt 分支
git push origin profile/kubevirt
```

---

## 二、main 分支改动范围（严格控制）

main 分支的目标：**与上游的 diff 越小越好**，只改品牌。

### 2.1 改动文件清单（目标 < 10 个文件）

```
修改的文件:
─────────────────────────────────────────────
pkg/machinery/constants/constants.go     ← OS 名称常量
pkg/machinery/gendata/data.go           ← 版本嵌入
Makefile                                ← 二进制名、镜像名

新增的文件:
─────────────────────────────────────────────
cmd/yanctl/main.go                      ← CLI 入口（引用原 talosctl 逻辑）
yanos.mk                               ← YanOS 专用构建目标
hack/yanos/os-release.template          ← /etc/os-release 模板
hack/yanos/issue.template               ← 控制台 banner
```

### 2.2 constants.go 改动示例

```go
// pkg/machinery/constants/constants.go
// 只改品牌字符串，不改逻辑

const (
    // YanOS branding
    OSName          = "YanOS"           // was "Talos"
    OSIdentifier    = "yanos"           // was "talos"  
    CLIName         = "yanctl"          // was "talosctl"
    ConfigDirName   = ".yanos"          // was ".talos"
    DefaultHomepage = "https://github.com/erhuoyan/yanos"
    
    // 以下全部保持 Talos 原值不变
    // APIPort, TrustdPort, KubeletPort, ...
)
```

### 2.3 yanctl 入口

```go
// cmd/yanctl/main.go — 极简，引用 talosctl 的逻辑
package main

import (
    "github.com/erhuoyan/yanos/cmd/talosctl/cmd"
)

func main() {
    cmd.Execute()
}
```

不复制 talosctl 的代码，直接引用。品牌切换靠 constants.go 的常量。

### 2.4 yanos.mk

```makefile
# yanos.mk
# 只覆盖品牌变量，include 原 Makefile

export USERNAME := erhuoyan
export REGISTRY := ghcr.io

# 入口目标
.PHONY: yanctl
yanctl:
	cd cmd/yanctl && go build -o ../../_out/yanctl .

.PHONY: yanos-iso
yanos-iso:
	$(MAKE) iso

.PHONY: yanos-release
yanos-release: yanctl yanos-iso
	@echo "YanOS built → _out/"
```

---

## 三、profile/kubevirt 分支改动范围

这个分支基于 main，**只新增文件和 build tag**，不修改 Talos 原有逻辑。

### 3.1 新增文件（零冲突）

```
internal/app/machined/pkg/controllers/yanos/
  ├── numa/
  │   └── topology.go              # NUMA 探测 + 亲和配置
  ├── cpu/
  │   └── isolation.go             # CPU 隔离策略
  ├── memory/
  │   ├── hugepages.go             # HugePages 声明式管理
  │   └── ksm.go                   # KSM 内存去重
  ├── network/
  │   ├── irqaffinity.go           # 中断亲和
  │   └── sysctltune.go            # 网络参数调优
  └── register.go                  # 控制器注册入口

pkg/machinery/config/types/yanos/
  ├── compute.go                   # compute 配置（NUMA/CPU/HugePages）
  └── validate.go                  # 配置校验

hack/yanos/
  └── kernel-config-kubevirt-amd64 # KVM 优化内核配置（可选）
```

### 3.2 build tag 排除模块（每个文件只加一行）

```
对不需要的模块加 //go:build !yanos_kubevirt：

internal/app/machined/pkg/controllers/kubespan/     # WireGuard mesh
internal/app/machined/pkg/controllers/siderolink/   # 商业管理平面
internal/pkg/secureboot/                           # Secure Boot
internal/pkg/uki/                                  # UKI
internal/pkg/encryption/                           # 磁盘加密
internal/pkg/discovery/                            # 节点发现
```

### 3.3 控制器注册

```go
// internal/app/machined/pkg/controllers/yanos/register.go
//go:build yanos_kubevirt

package yanos

func AdditionalControllers() []controller.Controller {
    return []controller.Controller{
        &numa.TopologyController{},
        &cpu.IsolationController{},
        &memory.HugePagesController{},
        &memory.KSMController{},
        &network.IRQAffinityController{},
        &network.SysctlTuneController{},
    }
}
```

### 3.4 machine-config 扩展

```yaml
# profile/kubevirt 支持的额外配置字段
apiVersion: v1alpha1    # 保持 Talos 原版 schema
kind: YanOSConfig      # 扩展配置
spec:
  compute:
    hugepages:
      ratio: 0.75
    numa:
      aware: true
    cpu:
      isolation: soft
      systemCores: 4
    ksm:
      enabled: false
```

---

## 四、Build Tag 体系

```
无 tag          → 原版 Talos（验证上游兼容性用）
-tags yanos     → YanOS 通用版（main 分支，只有品牌变化）
-tags yanos_kubevirt → YanOS KubeVirt 版（kubevirt 分支，含优化控制器）
```

```bash
# 构建原版 Talos（验证上游兼容性）
make talosctl

# 构建 YanOS 通用版
make -f yanos.mk yanctl                              # 自带 -tags yanos

# 构建 YanOS KubeVirt 版
make -f yanos.mk yanctl BUILDFLAGS="-tags yanos_kubevirt"
```

---

## 五、版本体系

```
YanOS 版本                    对应 Talos 版本     场景
──────────────────────────────────────────────────
YanOS 1.12.0                  Talos v1.12.0      通用
YanOS 1.12.0-kubevirt         Talos v1.12.0      KubeVirt 优化
YanOS 1.13.0                  Talos v1.13.0      通用
YanOS 1.13.0-kubevirt         Talos v1.13.0      KubeVirt 优化

版本号策略：跟 Talos 大版本号走，你的发布节奏对齐上游
好处：一眼知道基于哪个 Talos 版本，方便查上游 changelog
```

---

## 六、长期演进路线

```
Phase 1: 品牌 Fork（现在）
  main 分支: 只改品牌常量
  验证: yanctl version 显示 YanOS
  交付: yanctl 二进制 + ISO

Phase 2: KubeVirt Profile（1-2 月后）
  profile/kubevirt 分支: 加 NUMA/CPU/HugePages 控制器
  验证: 在你的三节点上跑 VM 对比性能
  交付: YanOS KubeVirt 版 ISO

Phase 3: 更多 Profile（按需）
  profile/edge:     边缘轻量化（精简内核、快速启动）
  profile/ai:       GPU 直通、CUDA 驱动（VFIO 优化）
  profile/storage:  存储节点（Ceph OSD 优化，如果以后需要混部）
  profile/bare:     最小化（纯跑容器，不跑 VM）

每个 profile 都是独立分支，都从 main merge 获取上游更新
```

---

## 七、目录结构总览

```
erhuoyan/yanos/
├── [Talos 原有代码全部保留，不删除任何文件]
│
├── cmd/
│   ├── talosctl/              # 保留（main 分支品牌通过常量切换）
│   └── yanctl/                # [新增] CLI 入口
│       └── main.go
│
├── internal/app/machined/pkg/controllers/
│   ├── kubespan/              # 保留，kubevirt 分支用 build tag 跳过
│   ├── siderolink/            # 保留，kubevirt 分支用 build tag 跳过
│   ├── network/               # 保留不动
│   ├── k8s/                   # 保留不动
│   └── yanos/                 # [新增，仅 kubevirt 分支]
│       ├── numa/
│       ├── cpu/
│       ├── memory/
│       ├── network/
│       └── register.go
│
├── pkg/machinery/
│   ├── constants/constants.go # [修改] 品牌常量（main 分支）
│   └── config/types/yanos/    # [新增，仅 kubevirt 分支]
│
├── hack/yanos/                # [新增] YanOS 构建资源
│   ├── os-release.template
│   ├── issue.template
│   └── kernel-config-kubevirt-amd64
│
├── yanos.mk                   # [新增] YanOS 构建入口
├── Makefile                    # [微调] 品牌变量
└── Dockerfile                  # [微调] 品牌变量
```

---

## 八、操作步骤

```
Step 1: 你在 GitHub 上 fork
  siderolabs/talos → erhuoyan/yanos
  Settings 里取消 "Fork only main" 限制（保留所有 tag）

Step 2: clone + 设置 remote
  git clone git@github.com:erhuoyan/yanos.git
  cd yanos
  git remote add upstream https://github.com/siderolabs/talos.git

Step 3: main 分支品牌改造（第一个 commit，< 200 行 diff）
  - 改 constants.go
  - 加 cmd/yanctl/main.go
  - 加 yanos.mk
  - 加 hack/yanos/

Step 4: 验证上游同步
  git fetch upstream
  git merge upstream/main    # 应该无冲突

Step 5: 建 profile/kubevirt 分支
  git checkout -b profile/kubevirt main
  - 加 build tag 排除不需要的模块
  - 加 yanos/ 控制器目录
  - 加 config types

Step 6: 构建验证
  make -f yanos.mk yanctl
  ./yanos/_out/yanctl version   # 应显示 YanOS
```
