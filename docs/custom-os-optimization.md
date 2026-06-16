# 自定义 K8s OS 优化分析：Talos 模式（存算分离架构）

> 计算节点专用优化：KubeVirt VM + Kube-OVN，外接存储
> 2026-06-16

---

## 一、产品架构定位

```
┌─────────────────────────────────────────────┐
│              计算节点（你的 OS）               │
│                                             │
│   KubeVirt VM × N                           │
│   K8s 控制面（etcd / apiserver / ...）       │
│   Kube-OVN (OVS)                            │
│   CSI 客户端 (iSCSI / RBD / NFS / ...)      │
│                                             │
│   不跑: Ceph OSD、分布式存储引擎             │
│   磁盘用途: OS + etcd + containerd 缓存     │
└──────────────────┬──────────────────────────┘
                   │ CSI (iSCSI/RBD/NFS/...)
                   ▼
┌─────────────────────────────────────────────┐
│              存储集群（独立）                  │
│   Ceph / MinIO / 商业 SAN / NAS / ...       │
│   独立硬件、独立维护、独立扩容               │
└─────────────────────────────────────────────┘
```

**核心含义**：计算节点的 CPU 和内存几乎全部给 VM，不需要跟存储服务争资源。优化方向极其聚焦——**虚拟化性能 + 网络性能**。

---

## 二、相比 Talos 原版的优化总览

| 层次 | 优化方向 | Talos 现状 | 你的 OS 可以做的 |
|------|---------|-----------|----------------|
| 内核 | KVM 深度优化 | 通用配置 | 编入内核 + vhost + NO_HZ |
| 内核 | 精简 | 兼容一切硬件 | 只保留你的硬件驱动 |
| CPU | NUMA 感知 | 无 | 自动拓扑探测 + 亲和 |
| CPU | 隔离 | 无 | 系统/VM 核分离 |
| 内存 | HugePages | 手动内核参数 | 声明式自动管理 |
| 内存 | NUMA 绑定 | 无 | VM 内存锁定在本地 NUMA |
| 网络 | OVS 调优 | 默认 | 多线程 + flow limit |
| 网络 | 中断亲和 | irqbalance | 按 NUMA 手动绑定 |
| 网络 | sysctl | 保守默认值 | 高 VM 密度参数 |
| 存储 | 本地磁盘 | 复杂分区 | 极简：OS+etcd 即可 |
| 系统 | machined | 通用 | 去掉云/加密/mesh 模块 |
| 调度 | kubelet | 需手动配 | 自动 topology manager |

---

## 三、内核优化

### 3.1 KVM 虚拟化（核心优化点）

```bash
# 编入内核（不走模块加载，启动即可用）
CONFIG_KVM=y
CONFIG_KVM_INTEL=y

# vhost — VM 网络性能关键
CONFIG_VHOST=y
CONFIG_VHOST_NET=y              # 数据路径在内核态，绕过 QEMU
CONFIG_VHOST_VSOCK=y            # VM ↔ Host 通信

# VirtIO 设备栈
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_MEM=y             # 内存热插拔

# 巨页
CONFIG_HUGETLBFS=y
CONFIG_HUGETLB_PAGE=y
CONFIG_TRANSPARENT_HUGEPAGE=y

# 减少 VM vCPU 被宿主中断打断
CONFIG_NO_HZ_FULL=y             # tickless 内核
CONFIG_HIGH_RES_TIMERS=y

# VFIO（GPU/NIC 直通预留）
CONFIG_VFIO=m
CONFIG_VFIO_PCI=m
CONFIG_VFIO_IOMMU_TYPE1=m

# CPU 频率
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y  # 固定最高频
```

**为什么 Talos 不这么做**：Talos 要兼容不跑 VM 的纯容器场景，KVM 只能做模块。你的 OS 100% 跑 VM，KVM 编入内核是确定的。

### 3.2 精简内核

存算分离后，计算节点不需要任何本地存储驱动（OSD 相关全删）：

```bash
# 删掉 — 存储相关
CONFIG_BLK_DEV_RBD=n            # 不需要内核 RBD（用 CSI userspace）
CONFIG_CEPH_FS=n                # 不需要内核 CephFS
CONFIG_XFS_FS=m                 # 只给 OS 分区用，模块即可
CONFIG_BTRFS_FS=n
CONFIG_BFQ_GROUP_IOSCHED=n      # 不需要 BFQ（没有 HDD OSD）

# 删掉 — 无用硬件
CONFIG_WIRELESS=n
CONFIG_BT=n
CONFIG_SOUND=n
CONFIG_DRM=n
CONFIG_FB=n
CONFIG_USB_STORAGE=n
CONFIG_INFINIBAND=n
CONFIG_MEDIA_SUPPORT=n
CONFIG_INPUT_JOYSTICK=n

# 保留 — 网络
CONFIG_BONDING=y
CONFIG_OPENVSWITCH=m
CONFIG_BPF=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
CONFIG_IP_VS=m                  # kube-proxy IPVS 模式

# 保留 — CSI 客户端可能用到
CONFIG_ISCSI_TCP=m              # iSCSI 存储对接
CONFIG_NFS_FS=m                 # NFS 存储对接
CONFIG_SCSI_FC_ATTRS=m          # FC SAN（看需要）
```

**预估内核大小**：从 Talos 的 ~12MB 压到 ~8MB。

### 3.3 内核启动参数

```bash
# machined 写入 GRUB 的默认内核参数
intel_iommu=on                  # IOMMU（VFIO 直通必须）
iommu=pt                        # passthrough 模式（不影响非直通设备性能）
kvm_intel.nested=1              # 嵌套虚拟化
kvm_intel.enable_apicv=1        # APICv 硬件加速虚拟中断
default_hugepagesz=2M           # 默认大页大小
transparent_hugepage=always     # THP 默认开启
nohz_full=4-N                   # 动态 tickless（系统核之外）
rcu_nocbs=4-N                   # RCU 回调不在 VM 核上
processor.max_cstate=1          # 禁用深度 C-state（牺牲功耗换延迟）
```

---

## 四、CPU 与 NUMA 优化

### 4.1 NUMA 感知 — NUMAController

双路 Xeon = 2 个 NUMA node，跨 NUMA 内存访问延迟增加 ~40%。

```
你的 machined NUMAController 启动时做的事：

1. 探测 NUMA 拓扑
   $ numactl -H
   node 0: cpus 0-9,20-29   memory 126GB
   node 1: cpus 10-19,30-39  memory 126GB

2. 绑定系统服务到 NUMA-0 的前几个核
   machined:    CPU 0-1
   apid/trustd: CPU 2
   etcd:        CPU 2-3    (etcd 对延迟敏感)
   apiserver:   CPU 0-3    (burst 时借用)

3. 声明 VM 可用资源
   NUMA-0 剩余: CPU 4-9,20-29 (16 vCPU) + ~120GB
   NUMA-1 全部: CPU 10-19,30-39 (20 vCPU) + ~126GB
   → kubelet allocatable: 36 CPU, ~246GB

4. 向 kubelet 注册 NUMA 拓扑
   kubelet --topology-manager-policy=single-numa-node
   → 保证每个 VM 的 vCPU 和内存在同一个 NUMA node
```

**效果**：大 VM（>8 核）的内存访问延迟降低 20-40%，尤其是数据库类 VM。

### 4.2 CPU 隔离 — CPUController

```
两种模式（machined 根据 config 选择）：

模式 A: 软隔离（默认，推荐起步）
  kubelet cpuManagerPolicy: static
  kubelet topologyManagerPolicy: single-numa-node
  VM 请求 Guaranteed QoS → kubelet 自动 pin CPU
  系统服务用 reservedSystemCPUs
  
  优点: 简单、kubelet 原生支持
  缺点: 非 Guaranteed Pod 仍可能干扰

模式 B: 硬隔离（高密度场景）
  内核参数: isolcpus=4-39 nohz_full=4-39
  系统只用 CPU 0-3
  VM 核完全不收内核中断
  
  优点: VM 尾延迟极低
  缺点: 灵活性降低，系统服务只有 4 核

machined config 中声明:
  machine:
    cpu:
      isolation: soft          # soft | hard
      systemCores: 4           # 保留给系统的核数
```

### 4.3 自动资源计算

Talos 需要你手动算 systemReserved / kubeReserved。你的 machined 可以自动做：

```
machined ResourceController 启动时：

  total_cpu = 探测物理核数          # 40
  total_mem = 探测总内存            # 252 GiB
  system_cpu = config.cpu.systemCores  # 4
  hugepages_mem = config.memory.hugepages_total  # 180 GiB

  自动生成 kubelet 配置：
    systemReserved:
      cpu: "{system_cpu * 1000}m"     # 4000m
      memory: "8Gi"
    allocatable:
      cpu: "{total_cpu - system_cpu}" # 36
      memory: "{total_mem - 8Gi - hugepages_overhead}"
      hugepages-2Mi: "{hugepages_mem}"
```

不再需要人工计算，换硬件也不用改配置。

---

## 五、内存优化

### 5.1 HugePages 声明式管理

```yaml
# machine-config.yaml
machine:
  memory:
    hugepages:
      defaultSize: 2Mi
      # 按比例自动计算，不写死数量
      # machined 启动时: (总内存 - 系统预留) × ratio
      ratio: 0.75              # 75% 内存做大页
    systemReserved: 8Gi        # 系统保留
```

machined HugePagesController 做的事：

```
启动时:
  1. 读取总内存: 252Gi
  2. 计算大页数: (252 - 8) × 0.75 / 2Mi = 93696 页 = 183Gi
  3. echo 93696 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
  4. 验证: cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages
  5. 向 kubelet 上报 allocatable hugepages-2Mi: 183Gi

运行时:
  - 监控大页使用率，不够时告警
  - 节点资源报告中显示大页利用率
```

**为什么 ratio 比固定数量好**：换了不同内存的硬件，config 不用改。

### 5.2 KSM (Kernel Same-page Merging)

如果节点上跑很多相同 OS 的 VM（比如全是 openEuler），KSM 可以合并相同内存页：

```bash
# machined 配置
echo 1 > /sys/kernel/mm/ksm/run
echo 1000 > /sys/kernel/mm/ksm/sleep_millisecs  # 扫描间隔
echo 500 > /sys/kernel/mm/ksm/pages_to_scan     # 每次扫描页数
```

**效果**：10 个相同 OS 的 VM，内存实际占用可降 20-30%。
**代价**：轻微 CPU 开销（扫描线程），延迟敏感场景慎用。

```yaml
# machine-config.yaml — 可选
machine:
  memory:
    ksm:
      enabled: true           # 默认关闭
      scanInterval: 1000ms
      pagesPerScan: 500
```

---

## 六、网络优化

### 6.1 中断亲和 — IRQAffinityController

```
machined 启动时：
  1. 发现网卡: ens1f0 (slot PCIe x16 on NUMA-0)
                ens1f1 (slot PCIe x16 on NUMA-1)
  2. 读取每个网卡的 IRQ 列表
  3. 按 NUMA 绑定:
     ens1f0 的 16 个 RX 队列 → NUMA-0 的核
     ens1f1 的 16 个 RX 队列 → NUMA-1 的核
  4. 设置 XPS（发送端也按 NUMA 分）
  5. 禁用 irqbalance
```

### 6.2 OVS 调优

```bash
# machined 的 OVN 控制器配置 OVS 参数
ovs-vsctl set Open_vSwitch . \
  other_config:n-handler-threads=4 \        # 多线程处理
  other_config:n-revalidator-threads=4 \    # 多线程 flow 重校验
  other_config:flow-limit=200000            # flow 表上限（默认太小）

# PMD（Poll Mode Driver）线程亲和 — 如果用 OVS-DPDK
# 当前用内核态 OVS 则不需要
```

### 6.3 网络 sysctl

```bash
# VM 密度高时必须调的参数

# conntrack — 每个 VM 都有连接，默认 65536 很快耗尽
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144

# ARP 表 — 大二层 + 多 VM
net.ipv4.neigh.default.gc_thresh3 = 16384

# TCP buffer — VM CSI 网络存储流量大
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# 网卡 backlog — 高吞吐
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
```

### 6.4 bond 配置优化

```yaml
# machine-config.yaml
machine:
  network:
    bond:
      name: bond0
      mode: 802.3ad
      slaves: [ens1f0, ens1f1]
      lacpRate: fast           # 快速 LACP 协商（默认 slow 要 30s）
      xmitHashPolicy: layer3+4
      miimon: 100              # 链路检测间隔 100ms
```

如果交换机支持 jumbo frame：

```yaml
      mtu: 9000               # Ceph 存储流量走大帧 → 吞吐提升 10-15%
                               # 前提: 物理交换机端口也配 9000
```

---

## 七、本地磁盘极简化

存算分离后，计算节点的本地磁盘只需要：

```
/dev/sda (或 NVMe):
├── EFI:   512M (UEFI 启动)
├── BOOT:  1G   (内核 + initramfs)
├── STATE: 1G   (machine-config, 证书, 节点身份)
├── ROOT:  20G  (SquashFS rootfs, 只读)
├── ETCD:  50G  (etcd 数据, XFS, 推荐在 NVMe 上)
└── VAR:   剩余 (kubelet, containerd cache, logs)

如果有 NVMe + HDD：
  NVMe → ETCD 分区（<1ms 延迟）
  HDD  → OS + VAR（不 care 性能）

如果只有 HDD（计算节点不需要好存储）：
  HDD → 全部分区
  etcd 性能靠 SSD cache 或 容忍稍高延迟
```

**对比 Talos 的 6 分区**：你不需要 META 分区（Talos 存云平台 metadata），也不需要 BIOS 分区（纯 UEFI）。

machined StorageController 在首次启动时自动分区：

```yaml
# machine-config.yaml
machine:
  storage:
    layout: auto              # 自动探测磁盘类型并分区
    etcd:
      preferNVMe: true        # 优先把 etcd 放 NVMe
      size: 50Gi
```

---

## 八、machined 精简后的 Controller 列表

```
你的 machined (存算分离，专注虚拟化)：

核心控制器（保留自 Talos）：
  ├── config.MachineConfigController    # 配置加载/验证
  ├── network.BondController            # bond 配置
  ├── network.AddressController         # IP 地址
  ├── network.RouteController           # 路由
  ├── network.DNSController             # DNS
  ├── certificate.TrustController       # 证书签发/轮换
  ├── k8s.EtcdController               # etcd 生命周期
  ├── k8s.ControlPlaneController        # apiserver/scheduler/cm
  ├── k8s.KubeletController            # kubelet 配置+启动
  └── upgrade.Controller                # 原子升级

专用控制器（新增，Talos 没有的）：
  ├── numa.TopologyController           # NUMA 探测 + 亲和配置
  ├── cpu.IsolationController           # CPU 隔离策略
  ├── memory.HugePagesController        # 大页管理
  ├── memory.KSMController              # KSM 内存去重（可选）
  ├── network.IRQAffinityController     # 中断亲和
  ├── network.SysctlTuneController      # 网络参数调优
  └── storage.AutoPartitionController   # 首次启动自动分区

从 Talos 删除的（不需要）：
  ✗ KubeSpanController                 # WireGuard mesh
  ✗ SideroLinkController              # 商业管理平面
  ✗ CloudProviderController            # AWS/GCP/Azure metadata
  ✗ SecureBootController               # TPM/UKI
  ✗ DiscoveryController                # 节点发现服务
  ✗ EncryptionController               # 磁盘加密
  ✗ MaintenanceModeController          # 无配置维护模式
  ✗ InstallController (复杂版)         # 多平台安装器
```

machined 从 ~50MB 压到 ~12-15MB。

---

## 九、优化优先级排序（存算分离版）

```
第一优先级（效果最大 + VM 直接受益）：
  1. ✅ 内核 KVM=y + vhost_net=y       → VM 网络吞吐 +30%
  2. ✅ NUMA 感知 + topology manager   → VM 延迟 -20~40%
  3. ✅ HugePages 声明式管理           → VM 内存延迟 -15%
  4. ✅ 内核精简（去掉存储/无用驱动）   → 启动快 + 攻击面小

第二优先级（系统层面收益）：
  5. ✅ 中断亲和                       → 网络延迟抖动减少
  6. ✅ CPU 软隔离 (cpuManager=static) → VM 尾延迟改善
  7. ✅ conntrack + sysctl 调优        → 高 VM 密度时不丢包
  8. ✅ etcd 独立分区（NVMe 优先）     → 集群稳定性

第三优先级（进阶）：
  9. ⚠️ nohz_full + rcu_nocbs         → VM vCPU 更"安静"
  10. ⚠️ CPU 硬隔离 (isolcpus)        → 需要仔细规划
  11. ⚠️ KSM 内存去重                 → 同质 VM 多时有用
  12. ⚠️ MTU 9000 (jumbo frame)       → 看交换机支持

未来可扩展（通过 system extension）：
  🔮 OVS-DPDK                         → 极端网络性能需求
  🔮 VFIO GPU 直通                    → GPU VM 场景
  🔮 SR-IOV                           → 网卡直通
```

---

## 十、最终架构图（存算分离版）

```
┌──────────────────────────────────────────────────────────┐
│               你的 K8s OS — 计算节点专用                    │
│                                                          │
│  machined (Go, PID 1, ~15MB)                             │
│  ┌────────────────────────────────────────────────────┐  │
│  │  COSI Controllers:                                 │  │
│  │    config / network / certificate / k8s / upgrade  │  │
│  │    + NUMA + CPU + HugePages + IRQ + sysctl  [专用] │  │
│  │  gRPC API (apid) + mTLS                            │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  内核 (~8MB, 精简)                                        │
│  ┌────────────────────────────────────────────────────┐  │
│  │  KVM(y) vhost_net(y) virtio(y)  — 虚拟化核心       │  │
│  │  bonding(y) OVS(m) eBPF(y)     — 网络              │  │
│  │  iSCSI(m) NFS(m)               — CSI 客户端        │  │
│  │  NO_HZ_FULL + HUGETLBFS        — 性能              │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  运行组件                                                 │
│  ┌────────────────────────────────────────────────────┐  │
│  │  etcd (NVMe, NUMA-0 绑定)                          │  │
│  │  kubelet (topology=single-numa-node, static CPU)   │  │
│  │  containerd → KubeVirt VM (HugePages, CPU pinned)  │  │
│  │  OVN/OVS (IRQ affinity, flow tuned)                │  │
│  │  CSI 客户端 → 外部存储                              │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  本地磁盘极简: EFI + BOOT + STATE + ROOT + ETCD + VAR    │
└──────────────────────────────────────────────────────────┘
        │
        │ CSI (网络存储)
        ▼
  ┌──────────────┐
  │  外部存储集群  │  Ceph / SAN / NAS / ...
  └──────────────┘
```
