# 自定义 K8s OS 方案：kubeasz 风格 + 不可变基座

> 基于 Talos 理念 + kubeasz K8s 运行方式的融合方案
> 2026-06-16

---

## 一、设计目标

| 目标 | 说明 |
|------|------|
| 装完即就绪 | OS 镜像预烘焙所有 K8s 组件，首次启动根据配置自动拉起集群 |
| kubeasz 风格运行 | apiserver/etcd/kubelet 等以二进制 + systemd service 运行 |
| 扩缩容简单 | 新节点：写 config → 装 OS → 自动加入集群 |
| 自主可维护 | 你控制镜像构建流水线，升级 = 构建新镜像 + 滚动替换 |

---

## 二、核心架构

```
┌────────────────────────────────────────────────────┐
│               你的 OS 镜像（ISO / PXE）              │
│                                                    │
│  ┌─ 不可变层 (SquashFS / 只读根) ────────────────┐  │
│  │  Rocky Minimal rootfs (精简)                  │  │
│  │  + containerd + runc + CNI plugins            │  │
│  │  + kubelet + kubectl                          │  │
│  │  + kube-apiserver + kube-scheduler            │  │
│  │  + kube-controller-manager + kube-proxy       │  │
│  │  + etcd                                       │  │
│  │ unit files (所有 K8s 组件)          │  │
│  │  + 你的 init-agent (Go/Shell)                 │  │
│  └───────────────────────────────────────────────┘  │
│                                                    │
│  ┌─ 可变层 (overlayfs → /var, /etc/kubernetes) ──┐  │
│  │  证书、kubeconfig、etcd 数据                   │  │
│  │  /etc/kubernetes/ssl/                         │  │
│  │  /var/lib/etcd/                               │  │
│  │  /var/lib/kubelet/                            │  │
│  └───────────────────────────────────────────────┘  │
│                                                    │
│  ┌─ CONFIG 分区 (首次启动读取) ───────────────────┐  │
│  │  machine-config.yaml                          │  │
│  │  - role: master / worker                      │  │
│  │  - node_ip: 10.226.140.17x                   │  │
│  │  - cluster_endpoint: https://VIP:6443         │  │
│  │  - join_token / bootstrap_token               │  │
│  │  - network: bond0, LACP, MTU...              │  │
│  └───────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

---

## 三、与 Talos 和 kubeasz 的对比

| 维度 | Talos | kubeasz (当前) | 你的 OS |
|------|-------|---------------|--------|
| OS 安装方式 | ISO/PXE | 手动装 Rocky + 跑 Ansible | ISO/PXE（自己构建的） |
| K8s 部署 | 内置自动 | Ansible 手动触发 7 步 | 内置自动（首次启动） |
| K8s 运行方式 | static pod + machined | **二进制 + systemd** | **二进制 + systemd** ✓ |
| 组件管理 | machined (Go) | systemctl | **systemctl** ✓ |
| 加节点 | talosctl apply-config | ezctl add-node | 装 OS（带 config）→ 自动加入 |
| CNI | 任选（config 声明） | 手动选 | 首次启动后手动装（灵活） |
| SSH | 无 | 有 | **有**（保留，运维用） |
| 根文件系统 | 只读 SquashFS | 普通读写 | **只读 + overlayfs** |
| 升级 K8s | 换镜像重启 | kubeasz upgrade | 换镜像滚动重启 |

---

## 四、首次启动流程

```
节点上电 → GRUB 加载内核 + initramfs
    │
    ▼
systemd 正常启动
    │
    ▼
init-agent.service (你的核心逻辑，After=network-online.target)
    │
    ├── 1. 读取 CONFIG 分区的 machine-config.yaml
    │
    ├── 2. 配置网络 (bond0, IP, 路由, DNS)
    │      └── 已经由 NetworkManager 根据 config 配好
    │
    ├── 3. 判断角色
    │      ├── role=first-master (第一个控制平面)
    │      │   ├── 生成 CA 证书 + 所有 K8s 证书
    │      │   ├── 写入 /etc/kubernetes/ssl/
    │      │   ├── 生成 kubeconfig 文件
    │      │   ├── 启动 etcd.service
    │      │   ├── 启动 kube-apiserver.service
    │      │   ├── 启动 kube-controller-manager.service
    │      │   ├── 启动 kube-scheduler.service
    │      │   ├── 启动 kubelet.service + kube-proxy.service
    │      │   └── 标记：集群就绪，等待其他节点加入
    │      │
    │      ├── role=master (后续控制平面)
    │      │   ├── 从 first-master 拉取 CA 证书
    │      │   │   └── 通过 join_token + HTTPS API 获取
    │      │   ├── 生成本节点证书
    │      │   ├── etcd 加入现有集群
    │      │   └── 启动所有控制平面组件
    │      │
    │      └── role=worker
    │          ├── 从 master 获取 CA + 签发 kubelet 证书
    │          ├── 生成 kubelet kubeconfig
    │          └── 启动 kubelet.service + kube-proxy.service
    │
    └── 4. 标记首次启动完成（写标记文件，后续重启跳过初始化）
```

**重启行为**：
- 非首次启动时，init-agent 检测到已初始化标记，直接退出
- systemd 照常启动 etcd、apiserver、kubelet 等服务（它们已 enable）
- 跟你现在 kubeasz 部署后的效果完全一样

---

## 五、machine-config.yaml 设计

```yaml
# /config/machine-config.yaml — 安装时写入 CONFIG 分区
apiVersion: v1
kind: MachineConfig
metadata:
  name: k8s-10-226-140-170

node:
  role: first-master          # first-master | master | worker
  ip: 10.226.140.170
  hostname: k8s-10-226-140-170

network:
  bond:
    name: bond0
    mode: 802.3ad
    slaves: [ens1f0, ens1f1]
    xmit_hash_policy: layer3+4
  addresses:
    - 10.226.140.170/27
  gateway: 10.226.140.161
  dns: [10.226.136.231]
  proxy:
    http: http://10.226.136.231:3128
    https: http://10.226.136.231:3128
    no_proxy: "localhost,127.0.0.1,10.68.0.0/16,172.20.0.0/16,10.226.140.0/24"

cluster:
  name: kubevirt-prod
  endpoint: https://10.226.140.181:6443    # VIP
  service_cidr: 10.68.0.0/16
  pod_cidr: 10.16.0.0/16                  # 留给 CNI 定义
  dns_domain: cluster.local

  # 加入集群用
  join_token: "xxxx.yyyyyyyyyyyy"
  ca_cert_hash: "sha256:abcdef..."

  # 组件版本（镜像里已预装，这里用于验证/选择）
  kubernetes_version: v1.35.4
  etcd_version: v3.5.21
  containerd_version: v2.1.4

  # apiserver 额外参数
  apiserver_extra_args:
    service-node-port-range: 30000-32767
    audit-log-maxage: "30"

  # kubelet 额外参数
  kubelet_extra_args:
    max-pods: "200"
    allowed-unsafe-sysctls: "net.ipv4.ip_forward,net.bridge.*"
```

---

## 六、镜像构建流水线

### 6.1 构建方式选择

**推荐方案：Packer + Kickstart**

```
你的构建仓库 (git)
├── Makefile
├── packer/
│   ├── myos.pkr.hcl            # Packer 模板
│   └── http/
│       └── ks.cfg              # Kickstart 自动化安装
├── rootfs/
│   ├── etc/
│   │   ├── systemd/system/
│   │   │   ├── kubelet.service
│   │   │   ├── kube-apiserver.service
│   │   │   ├── kube-controller-manager.service
│   │   │   ├── kube-scheduler.service
│   │   │   ├── kube-proxy.service
│   │   │   ├── etcd.service
│   │   │   └── init-agent.service
│   │   └── kubernetes/
│   │       ├── manifests/      # 配置模板
│   │       └── config/         # 组件配置模板
│   └── usr/local/bin/
│       └── init-agent          # 你的初始化程序
├── binaries/                   # 或从网上下载
│   ├── kubelet
│   ├── kubectl
│   ├── kube-apiserver
│   ├── kube-controller-manager
│   ├── kube-scheduler
│   ├── kube-proxy
│   ├── etcd
│   ├── etcdctl
│   ├── containerd
│   └── runc
└── scripts/
    ├── build-iso.sh
    └── generate-config.sh      # 为每个节点生成 machine-config
```

### 6.2 Kickstart 核心内容 (ks.cfg)

```bash
# 最小安装 + 自动分区
%packages --excludedocs
@^minimal-environment
# 只保留必需：NetworkManager, systemd, chrony, lvm2
# 排除：firewalld, sssd, cockpit, plymouth 等
%end

%post
# 1. 关闭不需要的服务
systemctl disable firewalld
systemctl disable kdump

# 2. 拷贝 K8s 二进制到 /usr/local/bin/
# (由 Packer provisioner 完成)

# 3. 安装 systemd unit files
# (由 Packer provisioner 完成)

# 4. 设置只读根（可选 — 见第七节讨论）
# ...

# 5. 系统调优 (sysctl, limits)
cat > /etc/sysctl.d/99-k8s.conf << EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
vm.swappiness = 0
fs.inotify.max_user_watches = 524288
EOF
%end
```

### 6.3 构建命令

```bash
# 构建 ISO
make iso K8S_VERSION=v1.35.4 ETCD_VERSION=v3.5.21

# 构建 PXE 镜像
make pxe K8S_VERSION=v1.35.4

# 输出
# _out/myos-v1.35.4-20260616.iso
# _out/myos-v1.35.4-20260616-vmlinuz
# _out/myos-v1.35.4-20260616-initrd.img
```

---

## 七、关于"不可变"的程度选择

你不需要做到 Talos 那么极端（无 SSH 无 shell）。务实的方案有三个档次：

### 方案 A：轻度不可变（推荐你从这里开始）

```
根文件系统：正常 xfs，但 K8s 二进制放在只读 /usr/local/bin/
配置文件：/etc/kubernetes/ 可写
SSH：保留
包管理：保留但日常不用（只在构建时用）
升级方式：构建新 ISO → 重装 OS（保留 /var 数据分区）
```

**优点**：实现最简单，kubeasz 现有逻辑几乎不用改，你熟悉的所有运维方式都保留
**缺点**：理论上还是能手动改系统

### 方案 B：中度不可变

```
根文件系统：SquashFS 只读 + overlayfs 可写层
/etc/kubernetes/、/var/lib/etcd/ 等走单独可写分区
SSH：保留
包管理：无（只读根，装不了东西）
升级方式：A/B 分区切换，原子升级
```

**优点**：真正的不可变，防漂移
**缺点**：需要做 SquashFS 打包流水线，调试麻烦（装不了额外工具）

### 方案 C：仅做"标准化镜像"（最务实）

```
根文件系统：普通 Rocky Minimal，但由你的构建流水线统一生产
不追求不可变，追求一致性：所有节点从同一镜像安装
SSH：保留
包管理：保留
升级方式：构建新镜像 → 加新节点 → 驱逐旧节点 → 完成
```

**优点**：最快落地，今天就能开始做
**缺点**：不能叫"不可变 OS"，但实际效果一样（你不会手动改）

---

## 八、扩缩容流程

### 加节点 (scale-out)

```bash
# 1. 生成该节点的 machine-config
./scripts/generate-config.sh \
  --role worker \
  --ip 10.226.140.173 \
  --join-token $(get-join-token) \
  --output /tmp/node173-config.yaml

# 2. 制作含 config 的安装介质（或 PXE 传参）
# 方式一：ISO + cloud-init
# 方式二：PXE 启动时通过 kernel cmdline 传 config URL
#         如 myos.config_url=http://10.226.140.170/configs/node173.yaml

# 3. 节点装机启动 → init-agent 自动加入集群

# 4. 如果有 CNI（Kube-OVN），新节点自动被 DaemonSet 覆盖
```

整个过程你只需要：**生成一个 config 文件 + PXE 启动**。

### 删节点 (scale-in)

```bash
# 1. drain
kubectl drain k8s-10-226-140-173 --ignore-daemonsets --delete-emptydir-data

# 2. 如果是 master，先从 etcd 移除
etcdctl member remove <member-id>

# 3. delete node
kubectl delete node k8s-10-226-140-173

# 4. 关机/重装
```

---

## 九、init-agent 实现方案

init-agent 是核心——它把 kubeasz 的 Ansible 逻辑变成节点本地自治。

### 方案选择

| 方案 | 实现 | 复杂度 | 可维护性 |
|------|------|--------|---------|
| **Shell 脚本** | 把 kubeasz playbook 逻辑翻译成 bash | ★★☆ | ★★★ 你最熟悉 |
| **Go 程序** | 类似 Talos machined 的简化版 | ★★★★ | ★★★★ 但需要 Go 技能 |
| **Python** | 翻译 Ansible 逻辑为 Python | ★★★ | ★★★ |

**推荐：Shell 脚本起步**（最快落地），后期如果有需要再用 Go 重写。

### init-agent.sh 核心逻辑（简化版）

```bash
#!/bin/bash
set -euo pipefail

CONFIG_PATH="/config/machine-config.yaml"
INIT_DONE="/var/lib/init-agent/.done"
K8S_DIR="/etc/kubernetes"
CERT_DIR="${K8S_DIR}/ssl"

# 已初始化则退出
[[ -f "$INIT_DONE" ]] && exit 0

# 读取配置 (用 yq 解析 YAML)
ROLE=$(yq '.node.role' $CONFIG_PATH)
NODE_IP=$(yq '.node.ip' $CONFIG_PATH)
CLUSTER_ENDPOINT=$(yq '.cluster.endpoint' $CONFIG_PATH)
SERVICE_CIDR=$(yq '.cluster.service_cidr' $CONFIG_PATH)

# 设置 hostname
hostnamectl set-hostname $(yq '.node.hostname' $CONFIG_PATH)

case "$ROLE" in
  first-master)
    # 生成 CA
    generate_ca_certs
    # 生成所有组件证书
    generate_component_certs "$NODE_IP"
    # 生成 kubeconfig
    generate_kubeconfigs "$CLUSTER_ENDPOINT"
    # 写 etcd 配置并启动
    configure_etcd --initial-cluster="$NODE_IP"
    systemctl enable --now etcd
    wait_for_etcd
    # 启动控制平面
    configure_apiserver "$NODE_IP" "$SERVICE_CIDR"
    systemctl enable --now kube-apiserver
    wait_for_apiserver
    systemctl enable --now kube-controller-manager
    systemctl enable --now kube-scheduler
    # 启动 kubelet
    configure_kubelet "$NODE_IP"
    systemctl enable --now kubelet kube-proxy
    ;;

  master)
    # 从 first-master 获取证书
    fetch_certs_from_cluster "$CLUSTER_ENDPOINT" "$JOIN_TOKEN"
    # etcd 加入集群
    etcdctl member add ...
    configure_etcd --join
    systemctl enable --now etcd
    # 启动控制平面 + kubelet
    ...
    ;;

  worker)
    # 获取 CA 证书 + 生成 kubelet 证书
    fetch_ca_cert "$CLUSTER_ENDPOINT" "$JOIN_TOKEN"
    generate_kubelet_cert "$NODE_IP"
    # 启动 kubelet
    configure_kubelet "$NODE_IP"
    systemctl enable --now kubelet kube-proxy
    ;;
esac

# 标记完成
mkdir -p /var/lib/init-agent
date > "$INIT_DONE"
```

这本质上就是 kubeasz 的 01-07 步骤打包成一个本地脚本。

---

## 十、升级 K8s 版本

```
构建新镜像（K8s v1.36.x）
    │
    ▼
方式一：滚动替换（推荐）
    ├── 加入新版本 worker → drain 旧 worker → 移除
    ├── 逐个替换 master（etcd 数据在 /var，保留）
    └── 最终全部节点运行新版本

方式二：原地升级（保留 SSH 时可行）
    ├── scp 新二进制到节点
    ├── systemctl restart kube-apiserver kubelet ...
    └── 本质上跟 kubeasz upgrade 一样
```

---

## 十一、落地路线图

```
Week 1-2: 基础镜像构建
  ├── 建立 git 仓库
  ├── 写 Packer 模板 + Kickstart
  ├── 下载/编译 K8s 二进制 v1.35.4
  ├── 写 systemd unit files（照搬 kubeasz 的）
  └── 产出第一个 ISO

Week 3: init-agent v1
  ├── 写 init-agent.sh (first-master 模式)
  ├── 本地 VM 测试：装 ISO → K8s 起来
  └── 加入 master/worker 模式

Week 4: 集成测试
  ├── 三节点全流程测试
  ├── Kube-OVN 安装验证
  ├── Ceph + KubeVirt 验证
  └── 扩缩容测试

Week 5+: 生产化
  ├── PXE 启动支持
  ├── config 分发机制（HTTP server / USB）
  ├── CI/CD 流水线（新版本自动构建 ISO）
  └── 文档
```

**最快 MVP**：2 周可以出第一个能用的 ISO，装完三节点 K8s 就 ready。

---

## 十二、建议的起步方式

**先用方案 C（标准化镜像）快速验证**，别一上来就追求 SquashFS 不可变：

1. Packer 构建一个含所有 K8s 二进制的 Rocky Minimal ISO
2. 写一个 `init-agent.sh` 完成首次启动自动部署
3. 在你现有三节点上验证全流程
4. 成功后再考虑是否要做 SquashFS 只读根

因为 kubeasz 的证书生成、etcd 初始化、kubelet 配置这些逻辑你已经熟了——init-agent 就是把这些 Ansible task 翻译成本地脚本。

---

## 参考项目

| 项目 | 说明 | 借鉴点 |
|------|------|--------|
| [Talos Linux](https://github.com/siderolabs/talos) | 不可变 K8s OS | 架构模式、构建流水线 |
| [k3os](https://github.com/rancher/k3os) (已停) | K3s 专用 OS | config 驱动首次启动 |
| [Flatcar Container Linux](https://github.com/flatcar/Flatcar) | 不可变容器 OS | A/B 升级、只读根 |
| [kubeasz](https://github.com/easzlab/kubeasz) | K8s Ansible 部署 | systemd units、证书逻辑 |
| [Harvester](https://github.com/harvester/harvester) | HCI + K8s OS | 类似目标（K8s+虚拟化 OS） |
