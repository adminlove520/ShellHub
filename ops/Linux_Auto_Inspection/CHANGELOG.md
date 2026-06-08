# Changelog

所有重大更新均记录于此，格式参考 [Keep a Changelog](https://keepachangelog.com/)。

## [Unreleased]

暂无待发布内容。

---

## [2.5] - 2026-06-08

### Added

- **跨发行版深度兼容** — `detect_os()` 支持 9 大系列（kylin / uos / rhel / debian / suse / arch / alpine / gentoo / other），多源 OS 检测（`/etc/os-release` / `/etc/kylin-release` / `/etc/centos-release` 等），统一输出 `OS_ID` / `OS_FAMILY` / `OS_PRETTY` / `OS_VER_MAJOR`
- **服务状态多轨兼容** — `safe_service_status()` 支持 systemctl → service → chkconfig → init.d 四级 fallback，CentOS 6 / 容器内（无 systemd）也能正确识别 active / inactive / notfound 三态
- **NTP 时间源四套全识别** — chronyd / ntpd (`ntpq`/`ntpstat`) / systemd-timesyncd / openntpd
- **容器运行时双支持** — `container_cmd()` 优先 docker，fallback podman（RHEL 8+ / Fedora 31+ 默认），CLI 兼容
- **防火墙多源识别** — firewalld / ufw / nftables / iptables / SuSEfirewall2 + systemd/sysvinit 双轨
- **磁盘 I/O fallback** — `iostat` 优先，`/proc/diskstats` 兜底（最小化镜像常无 sysstat 包）
- **网络路由三级 fallback** — `ip route` → `netstat -rn` → `route -n`
- **dmesg 权限保护** — 内核 5.0+ 默认 `dmesg_restrict=1` 时自动走 `journalctl -k` fallback
- **系统更新多包管理器全支持** — yum / dnf / apt / zypper / pacman / apk 六套，`OS_FAMILY` 路由，自动适配 Kylin/RHEL/Debian/SUSE/Arch/Alpine

### Changed

- **服务检查提速** — 一次性缓存 `ALL_UNITS`（`systemctl list-unit-files`），避免重复 fork，CentOS 6 场景下提升明显
- **CPU IDLE 检测简化** — `/proc/stat` 双读 200ms 间隔，精度足够（~0.1%），比 `top -bn1` 快近 1 秒
- **dmesg 一次性缓存** — OOM 检查 + 硬件错误共用一次 `safe_dmesg()` 调用，减少重复采集开销
- **shadow 直读替代 chage** — 密码过期计算从逐个 `chage` fork 改为直接读 `/etc/shadow` 字段（`lastchange` + `maxdays`），提速显著
- **SUID/SGID 合并 find** — 一次 `find` 同时获取 SUID 和 SGID 权限文件，减少文件系统扫描次数
- **主机名检测三级 fallback** — `hostname -I` → `ip addr` → `ifconfig`，适配最小化镜像可能无 iproute2 的情况

### Fixed

- `<<<` here-string 在部分 minimalist 镜像中失败的问题
- `OOM_COUNT` 算术错误（未初始化变量导致计算失败）
- `apt`/`dnf`/`yum check-update` 的 pipefail 退出码污染问题（`|| true` + 数字 sanitize 双重保护）
- 容器内 Docker 权限保护（不输出错误码，优雅降级）
- `lastb` 在无 `/var/log/btmp` 时不报错

---

## [2.4] - 2026-05-10

### Added

- **`--fast` / `--skip-update-check` / `--skip-ssl-check` 命令行参数**，快速模式跳过联网检查（推荐日常巡检）
- **第 17 章节"总体建议"** — 基于警告数据动态生成短期（1-3 天）/ 中期（1-4 周）/ 长期（1-6 个月）维护建议，3 列卡片布局
- **免责声明区** — 声明报告仅作参考，阈值需按业务调整
- **巡检 banner + `[N/19] (xx%)` 步骤进度** — 每步耗时可见

### Changed

- **HTML 模板重构（Token Insight 风）** — 蓝色 banner + 横向 metadata 字段、17 个章节加蓝色编号、Summary 卡片左图标右数字、4 列基本信息网格、左侧固定深色 nav + IntersectionObserver scroll-spy
- **性能优化（提速 60s → 8-15s）**：服务检查缓存、CPU IDLE 简化、dmesg 缓存、shadow 直读、SUID/SGID 合并 find

---

## [2.3] - 2026-05-10

### Added

- **SSL 证书过期检查** — 扫描 `/etc/letsencrypt/live` / `/etc/ssl/certs` / `/etc/pki/tls/certs` / `/etc/nginx/ssl` 等路径，提取 CN / 到期时间 / 剩余天数，剩余 < 30 天告警
- **JSON 输出格式** — `-f json`，含 host / metrics / ssl / updates / thresholds / result 六大字段，对接 Prometheus / 监控平台
- **Exit code 语义化** — `0` = 正常，`1` = 警告，`2` = 严重告警 / 脚本错误

### Changed

- **HTML 目录导航** — 左侧固定 TOC，IntersectionObserver scroll-spy 高亮当前章节

### Fixed

- 剩余 6 个轻微缺陷（错误处理 / 代码重复 / 魔法数字 / Bash 版本检查 / 日志详细 / HTML 转义完善）
- 累计修复 20 项已识别缺陷，全部 close

---

## [2.2] - 2026-05-09

### Changed

- CPU 检测函数化（`get_cpu_idle()`）
- 内存字节级精算（`free -b` 替代 `-h`）
- SELinux 配置增强（同时显示当前状态 + 配置文件）
- Docker 权限优雅处理
- 执行时间统计 + 版本号显示

### Fixed

- here-string 兼容性修复
- `OOM_COUNT` 算术错误修复
- HTML 表格列宽 CSS 优化

---

## [2.1] - 2026-05-09

### Added

- 依赖检查（缺工具立即退出）
- 多包管理器支持（Kylin / RHEL / Debian / SUSE 自动适配）

### Fixed

- `apt update` / `lastb` 权限保护（root 不足时跳过）
- 空密码账户判断逻辑修正（`!` / `*` 不算空密码）
- 大文件搜索性能优化（限定搜索路径 `/var /home /opt /usr/local`）

---

## [2.0] - 2026-04-08

### Added

- 初始版本，1100+ 行，20+ 检查维度
- 硬件信息采集（DMI）、虚拟化检测（vmware/kvm/hyperv/xen）
- 磁盘 I/O 统计、大文件扫描、文件描述符监控
- Docker 容器检查、内核参数（sysctl）13 项
- 彩色终端输出 + 告警计数