# setvps

`setvps` 是面向 Ubuntu/Debian VPS 的单文件交互式管理脚本，适合 AWS、GCP 以及普通云服务器。

## 功能

- 开启 Root SSH 密码登录，并生成一次性显示的 14 位随机密码。
- 创建 1G、2G 或 4G `/swapfile`，自动启用、验证并写入 `/etc/fstab`。
- 按服务器本机时区设置多个每日重启时间，支持单独或全部删除。
- 检测本机和公网 IPv4/IPv6。
- 设置“仅公网 IPv4”“仅公网 IPv6”“IPv4 优先后 IPv6”“IPv6 优先后 IPv4”。
- 从网卡已有全局地址中选择固定出站源 IP，并通过 systemd 在重启后重新应用。
- 检测并管理 BBR，按运行内核真实提供的能力选择 BBRv3、BBRv2 或系统原生 BBR，启用后验证并支持恢复。
- 安装后随时输入 `setvps` 打开菜单。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/alenyan888/setvps/main/setvps.sh -o /tmp/setvps.sh
sudo bash /tmp/setvps.sh --install
sudo setvps
```

也可以克隆仓库后安装：

```bash
git clone https://github.com/alenyan888/setvps.git
cd setvps
sudo bash setvps.sh --install
sudo setvps
```

## 命令行用法

```text
setvps                 打开交互式菜单
setvps ssh             设置 Root SSH 密码登录
setvps swap 1|2|4      创建 1G、2G 或 4G Swap
setvps reboot          管理每日重启时间
setvps ip              管理 IP 出站策略
setvps bbr             管理 BBR
setvps bbr auto        自动启用内核支持的最高可验证版本
setvps bbr v3|v2       仅在内核明确支持时启用指定版本
setvps bbr native      启用当前内核注册的 bbr
setvps bbr status|off  查看状态或关闭并恢复原设置
setvps status          查看状态
setvps --install       安装或更新命令
```

## IP 策略说明

优先模式通过 `/etc/gai.conf` 设置 glibc 地址选择顺序，适用于大多数使用系统域名解析的程序。明确指定 `-4`/`-6`、使用自带 DNS 或自带网络栈的程序可能忽略此顺序。

严格模式使用独立的 nftables 表，仅阻止另一协议族的**新建公网连接**。以下流量仍被允许，以降低远程服务器失联风险：

- 已建立及关联连接；
- 回环流量；
- IPv4 私网、链路本地和云元数据网段；
- IPv6 链路本地和组播流量。

固定源 IP 只能从网卡上真实配置的 `scope global` 地址中选择。AWS/GCP 的 NAT 或弹性公网 IPv4 通常不会直接出现在网卡上，此时应选择对应的本机私网地址，公网转换仍由云平台完成。

公网 IP 检测会并行测试 IPv4 和 IPv6，并依次尝试 `api64.ipify.org`、`icanhazip.com` 和 `ifconfig.co`。每个节点使用更宽裕的连接及总超时时间，成功时同时显示返回地址和检测节点。全部节点失败时显示“未确认”，不会仅凭一次 HTTP 超时就断言该协议族不可用；默认路由信息会单独显示，便于区分本机路由与外部检测服务故障。

## BBR 说明

`setvps bbr auto` 只会在**当前运行内核已经提供**的实现中选择最高、可验证的版本，顺序为：

1. `tcp_bbr` 模块版本明确为 3，或供应商内核另行注册 `bbr3`：BBRv3；
2. 内核明确注册 `bbr2`，或 `tcp_bbr` 模块版本明确为 2：BBRv2；
3. 内核注册 `bbr` 但未暴露代际：系统原生 BBR；官方 Ubuntu/Debian 内核通常属于主线 BBRv1。

标准 sysctl 接口中的算法名 `bbr` 本身不能证明它是 v1 还是 v3，因此脚本不会按 Ubuntu/Debian 版本或内核版本号猜测。Google 的 [BBRv2 分支](https://github.com/google/bbr/tree/v2alpha)仍标记为 Alpha/Preview；[BBRv3 官方说明](https://github.com/google/bbr/tree/v3)要求构建并安装带补丁的内核。为避免 AWS/GCP 实例因内核或启动配置不兼容而失联，脚本不会自动下载、编译或替换内核。

启用时脚本设置 `net.core.default_qdisc=fq`，将当前内核对应的 `bbr`/`bbr2`/`bbr3` 设为默认 TCP 拥塞控制算法，并写入独立的 `sysctl.d` 与 `modules-load.d` 文件。完成后会核对运行值、已注册算法和持久化文件；`setvps bbr off` 会恢复首次接管前的默认算法与 qdisc。变更只影响新建 TCP 连接，现有 SSH 连接会继续使用建立时的算法。

## 安全提示

开启公网 Root 密码登录会增加暴力破解风险。建议同时采取以下措施：

- 在 AWS Security Group、GCP Firewall 或主机防火墙中仅允许可信来源 IP 访问 SSH；
- 使用高强度且不复用的密码；
- 能使用密钥时优先保留密钥登录作为备用；
- 修改网络策略后，先保持当前 SSH 会话，再从新窗口测试能否重新连接。

脚本修改 SSH 前会备份 `/etc/ssh/sshd_config`，并在重载服务前执行 `sshd -t` 和有效配置检查。

## 支持范围

- Ubuntu（使用 systemd）
- Debian（使用 systemd）
- Bash 4+

## License

MIT
