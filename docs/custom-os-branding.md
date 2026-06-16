# 自定义 OS 可定制项清单

> 你的 OS 从内核到品牌的完整定制范围
> 2026-06-16

---

## 一、内核选择

你有三条路线：

### 路线 A：上游主线内核（推荐）

```
来源: kernel.org（与 Talos 相同策略）
当前稳定版: Linux 6.12.x (LTS) 或 6.15.x (最新稳定)
编译工具链: musl (与 Talos 一致) 或 glibc

优点:
  ✅ 最新硬件支持 + 最新 KVM 优化
  ✅ 不依赖任何发行版
  ✅ 完全自主可控
  ✅ 社区活跃、补丁多

缺点:
  ❌ 需要自己维护 .config
  ❌ 没有发行版
  ❌ 需要自己跟踪 CVE 修复
```

### 路线 B：发行版内核（省心）

```
来源: Rocky/RHEL 内核 (kernel-5.14.x 或 kernel-6.12.x for EL10)
      或 Ubuntu 内核 (kernel-6.8.x / 6.11.x HWE)

优点:
  ✅ 已验证的硬件兼容性
  ✅ 长期安全补丁自动 backport
  ✅ 不需要自己追 CVE

缺点:
  ❌ 版本通常比主线落后 1-2 年
  ❌ KVM 优化不是最新
  ❌ 内核 .config 里带了大量你不需要的东西
  ❌ 依赖发行版生态
```

### 路线 C：自己 fork + 维护（长期推荐）

```
来源: fork kernel.org 主线到你的 git 仓库
策略: 跟踪某个 LTS 分支（如 6.12.x），定期 rebase

your-org/linux-kubevirt:
├── 基础: Linux 6.12.x LTS
├── 自定义 .config（精简 + KVM 优化）
├── 可选补丁: KVM 性能改进、安全加固
└── 品牌定制: LOCALVERSION、默认 cmdline

优点:
  ✅ 完全自主
  ✅ LTS 保证 6 年支持
  ✅ 可以 cherry-pick 上游新特性
  
维护量:
  LTS 内核每 1-2 周出小版本 (6.12.1 → 6.12.2 → ...)
  你只需要 rebase + 跑一遍你的测试
  工作量: 每月 1-2 天
```

**建议：路线 C**，选一个 LTS 分支作为基础，自己维护 .config。

---

## 二、完整可定制项清单

### 2.1 操作系统身份

| 定制项 | 文件/位置 | 示例 |
|--------|----------|------|
| **OS 名称** | `/etc/os-release` | `NAME="YunOS"` |
| **OS ID** | `/etc/os-release` | `ID=yunos` |
| **OS 版本** | `/etc/os-release` | `VERSION="1.0.0"` |
| **OS 版本代号** | `/etc/os-release` | `VERSION_CODENAME="kunlun"` |
| **OS 完整名称** | `/etc/os-release` | `PRETTY_NAME="YunOS 1.0 (Kunlun)"` |
| **主页 URL** | `/etc/os-release` | `HOME_URL="https://your-domain.com"` |
| **Bug 报告 URL** | `/etc/os-release` | `BUG_REPORT_URL="https://..."` |
| **ANSI 颜色** | `/etc/os-release` | `ANSI_COLOR="0;34"` |
| **OS logo** | `/etc/os-release` + 启动 | `LOGO="yunos-logo"` |

```bash
# 完整 /etc/os-release 示例
NAME="YunOS"
ID=yunos
ID_LIKE=talos
VERSION="1.0.0"
VERSION_ID=1.0.0
VERSION_CODENAME=kunlun
PRETTY_NAME="YunOS 1.0.0 (Kunlun)"
HOME_URL="https://your-domain.com"
BUG_REPORT_URL="https://github.com/your-org/yunos/issues"
ANSI_COLOR="0;34"
```

### 2.2 内核身份

| 定制项 | 配置方式 | 示例 | 效果 |
|--------|---------|------|------|
| **内核本地版本** | `CONFIG_LOCALVERSION` | `"-yunos"` | `uname -r` → `6.12.8-yunos` |
| **内核版本后缀** | `EXTRAVERSION` in Makefile | `-yunos.1` | `6.12.8-yunos.1` |
| **内核默认主机名** | `CONFIG_DEFAULT_HOSTNAME` | `"yunos"` | 无 hostname 时显示 |
| **内核编译者标识** | 环境变量 `KBUILD_BUILD_USER` | `"yunos-builder"` | `uname -a` 中显示 |
| **内核编译主机** | 环境变量 `KBUILD_BUILD_HOST` | `"yunos-ci"` | `uname -a` 中显示 |
| **内核编译时间戳** | `KBUILD_BUILD_TIMESTAMP` | `"2026-06-16"` | 可复现构建 |

```bash
# 编译后效果
$ uname -a
Linux k8s-node01 6.12.8-yunos.1 #1 SMP yunos-builder@yunos-ci 2026-06-16 x86_64

$ uname -r
6.12.8-yunos.1
```

### 2.3 启动界面

| 定制项 | 方式 | 说明 |
|--------|------|------|
| **GRUB 主题** | GRUB theme 目录 | 启动菜单界面、背景图、字体 |
| **GRUB 菜单项名称** | `grub.cfg` | `menuentry "YunOS 1.0"` |
| **启动 splash** | 内核 framebuffer 或 Plymouth | 开机动画/logo |
| **控制台 banner** | `/etc/issue` | 登录前显示的文字 |
| **MOTD** | `/etc/motd` 或动态生成 | 登录后显示的信息 |
| **SSH banner** | `/etc/ssh/sshd_config Banner` | SSH 连接前显示 |

```
# /etc/issue 示例（控制台登录前）
\e[1;34m
  __   __              ___  ____  
  \ \ / /   _ _ __    / _ \/ ___| 
   \ V / | | | '_ \  | | | \___ \ 
    | || |_| | | | | | |_| |___) |
    |_| \__,_|_| |_|  \___/|____/ 
\e[0m
  YunOS v1.0.0 | Kernel \r | \m
  Node: \n | IP: \4

```

### 2.4 CLI 管理工具

| 定制项 | Talos 中叫 | 你可以叫 | 说明 |
|--------|-----------|---------|------|
| **CLI 工具名** | `talosctl` | `yunosctl` / `yctl` | 管理节点的命令行 |
| **CLI 帮助文本** | Talos 品牌 | 你的品牌 | `--help` 输出 |
| **CLI 版本号** | Talos 版本 | 你的版本 | `yctl version` |
| **API 端口** | 50000 | 自定义 | gRPC 端口 |
| **配置文件名** | `talosconfig` | `yunosconfig` | `~/.yunos/config` |

```bash
# 效果
$ yctl version
Client:
  Tag:         v1.0.0
  SHA:         a1b2c3d
  Built:       2026-06-16
Server:
  Tag:         v1.0.0
  OS:          YunOS
  Kernel:      6.12.8-yunos.1
  Arch:        amd64
  Kubernetes:  v1.35.4

$ yctl dashboard --nodes 10.226.140.170
┌─ YunOS Dashboard ─────────────────────────────┐
│  Node: k8s-10-226-140-170                      │
│  OS:   YunOS 1.0.0 (Kunlun)                   │
│  K8s:  v1.35.4                                 │
│  CPU:  2×Xeon 4210 (40C) NUMA×2               │
│  Mem:  252 GiB (HugePages: 183 GiB)           │
│  VMs:  12 running                              │
│  Net:  bond0 2×25G LACP                        │
└────────────────────────────────────────────────┘
```

### 2.5 machined / 系统服务

| 定制项 | 说明 |
|--------|------|
| **PID 1 进程名** | `machined` → `yunos-machined` 或保持 |
| **API 服务名** | `apid` → `yunos-apid` 或保持 |
| **信任服务名** | `trustd` → `yunos-trustd` 或保持 |
| **machine-config schema** | `apiVersion: yunos.io/v1` |
| **证书 Organization** | `organization: "YunOS"` |
| **日志前缀** | `[yunos]` |
| **gRPC service name** | `yunos.api.MachineService` |

### 2.6 镜像与分发

| 定制项 | 说明 |
|--------|------|
| **ISO 文件名** | `yunos-1.0.0-amd64.iso` |
| **PXE 启动标识** | DHCP option 识别 |
| **OCI 镜像仓库** | `ghcr.io/your-org/yunos/installer:v1.0.0` |
| **系统扩展格式** | `yunos.io/v1alpha1` manifest |
| **Image Factory** | 自建的镜像工厂（可选） |

### 2.7 运行时可配置项（machine-config）

这些不是"品牌定制"，是功能配置，但也是你设计的：

```yaml
apiVersion: yunos.io/v1
kind: MachineConfig
metadata:
  name: k8s-node-01
spec:
  # 你自己定义的 schema，可以比 Talos 更简洁
  node:
    role: master
    ip: 10.226.140.170
  cluster:
    name: kubevirt-prod
    endpoint: https://10.226.140.181:6443
    kubernetes: v1.35.4
  compute:
    hugepages:
      ratio: 0.75
    numa:
      aware: true
    cpu:
      isolation: soft
      systemCores: 4
  network:
    bond:
      mode: 802.3ad
      slaves: [ens1f0, ens1f1]
  storage:
    etcd:
      preferNVMe: true
```

---

## 三、版本号体系设计

建议用**两条版本线**：

```
OS 版本: YunOS 1.x — 你的发布节奏
  └── 包含特定版本的:
      ├── 内核: 6.12.x-yunos
      ├── K8s:  v1.35.x
      ├── etcd: v3.5.x
      ├── containerd: v2.x
      └── machined: v1.x

版本矩阵示例:
  YunOS 1.0.0 = 内核 6.12.8  + K8s 1.35.4 + etcd 3.5.21
  YunOS 1.1.0 = 内核 6.12.12 + K8s 1.36.0 + etcd 3.5.23
  YunOS 2.0.0 = 内核 6.18.x  + K8s 1.38.x + etcd 3.6.x  (大版本跳)
```

---

## 四、构建产物

```
make release VERSION=1.0.0

_out/
├── yunos-1.0.0-amd64.iso              # 可启动安装 ISO
├── yunos-1.0.0-amd64-vmlinuz          # 内核（PXE 用）
├── yunos-1.0.0-amd64-initramfs.xz     # initramfs（PXE 用）
├── yunos-1.0.0-amd64-metal.raw.xz     # 裸金属磁盘镜像
├── yunos-installer:1.0.0              # OCI 安装器镜像
├── yunos-imager:1.0.0                 # OCI 镜像生成器
├── yctl-linux-amd64                   # CLI 工具 (Linux)
├── yctl-darwin-amd64                  # CLI 工具 (macOS)
└── SHA256SUMS                         # 校验和
```

---

## 五、总结：你能改的 vs 不需要改的

```
✅ 必须定制（你的身份）:
  - OS 名称、版本、代号
  - 内核 LOCALVERSION
  - CLI 工具名和品牌
  - machine-config schema
  - /etc/os-release
  - 启动界面 (GRUB + console banner)

✅ 应该定制（差异化价值）:
  - 内核 .config（KVM 优化 + 精简）
  - machined 控制器（NUMA/CPU/HugePages）
  - kubelet 自动配置逻辑
  - 分区策略

⚠️ 可以定制但不急（后期）:
  - 启动 splash 动画
  - dashboard TUI 界面
  - 自建 Image Factory
  - 系统扩展 manifest 格式

❌ 不需要改（保持与上游一致）:
  - gRPC/Protobuf 通信协议（可以跟 Talos 生态兼容）
  - COSI 控制器框架（直接用 cosi-project/runtime）
  - containerd（直接用上游）
  - etcd（直接用上游）
  - K8s 组件二进制（直接用上游）
```
