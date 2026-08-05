# EdgePi E87N daede 固件设计

日期：2026-08-04

## 1. 目标

为 Hiveton EdgePi E87N 构建一套可复现、可在线编译、可通过现有 U-Boot Web 恢复环境刷写的 ImmortalWrt 固件。固件以 ImmortalWrt 25.12、Linux 6.12、`mediatek/filogic` 和 ARM64 Cortex-A53 为基础，同时集成 dae、daed、常用网络服务、Python 3、Argon 主题、AdGuard Home，以及 E87N 的定制风扇控制功能。

构建项目使用公共 GitHub 仓库。仓库从 `kenzok8/imagebuilder` fork，保留其手动触发、Artifact、Release、校验和与 daede 软件包处理思路，但将 ImageBuilder 拼包流程重写为完整 ImmortalWrt 源码构建流程。

## 2. 已确认的设备基线

现有固件 `HiGoROS-E87N-1-26-05-09-02.bin` 的 SHA-256 为：

`054C31B71B24A1924B810B5CE1CE7480460871C134E58BB24907C3BEB1EE5AFA`

镜像是 OpenWrt 风格的 sysupgrade TAR，板级 ID 为 `edgepi,e87n`，包含 ARM64 FIT 内核和 SquashFS 根文件系统。现有内核为 Linux 6.6.94，系统为 ImmortalWrt 24.10-SNAPSHOT。

设备使用约 8 GB eMMC，已确认的分区为：

| 分区 | 大小 | 用途 |
| --- | ---: | --- |
| `mmcblk0p1` | 512 KiB | `u-boot-env` |
| `mmcblk0p2` | 4 MiB | `factory`，包含校准和设备身份数据 |
| `mmcblk0p3` | 2 MiB | `fip` |
| `mmcblk0p4` | 32 MiB | `kernel` |
| `mmcblk0p5` | 约 7.2 GiB | `rootfs` 与 F2FS overlay |

U-Boot Web 恢复方式为按住 Reset 上电数秒，然后访问 `192.168.1.1`。该恢复环境接受现有 sysupgrade 格式固件。新固件不得写入或修改 eMMC boot0/boot1、`u-boot-env`、`factory` 或 `fip`。

## 3. 构建架构

### 3.1 源码与版本锁定

构建基于 ImmortalWrt 25.12 分支。在首次成功完成 E87N 内核构建时，将使用的 ImmortalWrt、packages、LuCI、openwrt-daede 及其他外部依赖提交号写入版本锁定文件。后续构建默认使用这些固定提交，仅在显式更新时变更。

GitHub Actions 使用 `ubuntu-24.04`。Workflow 在编译前移除不需要的预装工具以释放磁盘，只缓存下载目录 `dl/`，不缓存 `build_dir` 或 `staging_dir`。构建设置足够长的超时，并在磁盘空间不足或超过托管 runner 时间限制时明确失败，不发布不完整镜像。

### 3.2 E87N 平台适配

从现有 FIT 中提取的 E87N DTB将重建为可维护 DTS，并适配 Linux 6.12。设备定义至少保留并验证：

- `edgepi,e87n`、`mediatek,mt7987a`、`mediatek,mt7987` compatible；
- eMMC 与现有 GPT 分区标签；
- 两个以太网 MAC/PHY，包括 2.5G PHY 与内部 PHY；
- 两个 PCIe 控制器及 NVMe 支持；
- USB 3 控制器；
- NV3007 SPI 屏，142×428、旋转 270°、52 MHz；
- PWM 控制器 `10048000.pwm`；
- `pwm-fan` 节点及原冷却级别；
- Reset、WPS、系统 LED 和状态 LED；
- factory 分区中的 MAC 地址与校准数据引用。

NV3007 若未包含在 6.12 基线内核中，则以独立、可审查的内核补丁加入。首版只要求内核正确创建 framebuffer；不复制完整 HiGoROS 显示服务。屏幕内容展示可以在基础固件稳定后单独迭代。

### 3.3 内核能力

内核必须启用并验证：

- `CONFIG_DEBUG_INFO_BTF` 与 `/sys/kernel/btf/vmlinux`；
- BPF、BPF syscall、BPF JIT 与 dae/daed 所需的调度 BPF能力；
- `kmod-sched-core`、`kmod-sched-bpf`、`kmod-veth`、XDP socket 诊断；
- nftables socket、TPROXY 和透明代理相关模块；
- WireGuard、TUN；
- PWM、HWMON、pwm-fan；
- NVMe、USB 存储、ext4、F2FS 和 Btrfs；
- E87N 网口、PHY、GPIO 和 framebuffer 所需驱动。

不得使用与目标内核版本不匹配的外置 `vmlinux-btf` 包替代内置 BTF。

## 4. 软件包设计

### 4.1 代理与网络服务

固件内置：

- `dae`、`daed`、`luci-app-daede`；
- AdGuard Home；
- WireGuard、`wireguard-tools`、`luci-proto-wireguard`；
- Tailscale；
- `luci-app-ddns` 与常用 DDNS 脚本；
- `watchcat`、`luci-app-watchcat`；
- `ttyd`、`luci-app-ttyd`；
- `vlmcsd`、`luci-app-vlmcsd`。

dae 与 daed 同时安装，但通过 daede 只运行一个后端。AdGuard Home 安装后不在未配置状态下抢占 dnsmasq 的 53 端口。Tailscale、WireGuard、DDNS、Watchcat 和 KMS 不预置账号、密钥或外部服务配置。

### 4.2 界面与工具

Argon 是默认 LuCI 主题，同时保留 Bootstrap 作为回退。固件包含简体中文界面。

Python 采用 Python 3，包含 pip 及常用 SSL、JSON 和 SQLite 支持。常用维护工具至少包含 `curl`、`wget-ssl`、`bash`、`nano`、`htop`、`btop`、`jq`、`lsblk`、`block-mount`、`smartmontools`、`iperf3` 和 `ethtool`。

### 4.3 风扇控制

现有风扇功能由 `fancontrol`、`luci-app-fancontrol` 和中文翻译包组成。已保存的 ARM64 风扇程序 SHA-256 为：

`DEDEA6CDB2FD7A65614501D2FB8C1FD58E3A1B16CC159EC07D775E5F78604FF8`

该程序使用标准 UCI 与 HWMON/PWM 接口，不依赖 HiGoROS 守护进程。它将作为本地 feed 软件包加入仓库，并保留 LuCI 页面、中文翻译、启动脚本和默认曲线。

运行时映射为：

- CPU 温度源：`cpu_thermal`；
- PWM 平台控制器：`10048000.pwm`；
- 风扇驱动：`pwmfan`；
- PWM 输出：`pwm1`；
- 无有效风扇转速反馈输入。

风扇控制默认启用，并使用已保存的均衡温度曲线。程序必须优先按 HWMON 设备名称查找 `pwmfan`，不能依赖可能随启动顺序变化的固定 `hwmon2` 编号。

## 5. 镜像与默认行为

输出保持与现有设备一致的 sysupgrade 结构：

```text
sysupgrade-edgepi,e87n/
├── CONTROL
├── kernel
└── root
```

`CONTROL` 必须声明 `BOARD=edgepi,e87n`。`kernel` 为包含 Linux 6.12 与 E87N DTB 的 ARM64 FIT，`root` 为 SquashFS。生成过程同时产出完整功能版和最小救援版。

默认 LAN 地址保持 `192.168.1.1`。不写入 root 密码、SSH 私钥、公钥、代理订阅、VPN 密钥、Tailscale Auth Key 或 DDNS 凭据。ttyd 只允许从 LAN 访问。

## 6. GitHub Actions 流程

公共 fork 保留上游来源和历史，但重写现有 x86 ImageBuilder workflow。新的手动 workflow执行：

1. 检出构建仓库；
2. 清理 runner 磁盘；
3. 拉取固定提交的 ImmortalWrt 和 feeds；
4. 安装 E87N 设备定义、内核补丁和本地 feed；
5. 更新并安装 feeds；
6. 生成完整版配置并执行全源码编译；
7. 生成救援版配置并复用可安全复用的构建产物；
8. 验证内核、DTB、BTF、sysupgrade 元数据、镜像大小和包清单；
9. 生成 SHA-256、构建清单和 SBOM/manifest；
10. 上传 GitHub Actions artifacts；
11. 仅在显式选择发布时创建 GitHub Release。

Artifact 至少包含：

- E87N 完整版 sysupgrade；
- E87N 最小救援版 sysupgrade；
- SHA-256 文件；
- 软件包 manifest；
- 最终 `.config`；
- 版本锁定文件；
- E87N DTS 编译结果或验证摘要；
- 构建与验证日志摘要；
- 刷写和恢复说明。

公共仓库不得包含 `factory`、FIP、eMMC boot 分区、MAC 地址、序列号、路由器配置备份或其他设备专属秘密。

## 7. 备份与恢复

刷写前通过 SSH 将下列数据直接传输到用户电脑，并计算 SHA-256：

- GPT 分区表；
- `mmcblk0boot0` 与 `mmcblk0boot1`；
- `u-boot-env`；
- `factory`；
- `fip`；
- 当前 `kernel`；
- 当前完整 rootfs 分区，或原 sysupgrade 镜像加配置备份。

备份过程只读取设备，不将备份临时写入同一块 eMMC。恢复说明必须明确区分普通 sysupgrade 回滚与底层分区恢复；在没有 TTL 的情况下，不指导用户从 Linux 写入 boot0、boot1、factory 或 FIP。

启动失败时，使用按 Reset 上电进入的 U-Boot Web 恢复页，通过 `192.168.1.1` 刷回已知可用的原 sysupgrade 镜像。

## 8. 验证与验收

### 8.1 构建期验证

- `CONTROL` 板级 ID 正确；
- FIT 可解析，包含 Linux 6.12 和 E87N DTB；
- DTB 的关键硬件节点与现有设备一致；
- kernel 镜像不超过 32 MiB；
- rootfs 布局符合现有启动参数；
- BTF 已生成；
- daed 所需内核模块和用户空间包均在 manifest 中；
- `sysupgrade -T` 能在当前 E87N 系统上通过兼容性检查；
- 完整版和救援版均生成 SHA-256。

### 8.2 首次启动验收

按以下顺序测试：

1. 两个网口、LAN 地址和 DHCP；
2. SSH 与 LuCI；
3. eMMC SquashFS 与 F2FS overlay；
4. CPU 温度读取、PWM 风扇自动启动和均衡曲线；
5. NVMe、USB 与 framebuffer；
6. `/sys/kernel/btf/vmlinux` 与简单 eBPF 加载；
7. dae 和 daed 分别启动、停止和切换；
8. AdGuard Home、WireGuard、Tailscale、DDNS、ttyd、KMS 与 Watchcat；
9. 正常重启；
10. 断电后的冷启动。

任一关键硬件验收失败时，停止继续启用高级服务，保留日志并通过 U-Boot Web 回滚。基础固件稳定后，再单独迭代小屏显示内容和非关键软件包。

## 9. 完成标准

本项目在以下条件全部满足时视为完成：

- 公共 GitHub fork 可通过手动 Actions workflow 从固定源码提交构建；
- 完整版与救援版均可下载并通过自动验证；
- E87N 能从完整固件启动并通过关键硬件验收；
- daed 能在内置 BTF 内核上正常启动；
- 风扇在启动早期进入安全自动控制状态；
- 原 U-Boot/FIP/factory 数据未被修改；
- 用户拥有可验证的设备备份、原固件和回滚说明。
