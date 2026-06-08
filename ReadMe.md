# ShellHub

安全运维工具集 —— 集安全基线加固、应急响应、日常运维于一体的脚本仓库。

## 目录结构

```
ShellHub/
├── security/              # 安全基线加固
│   ├── security_kylin.sh  # ★ 等保三级安全基线加固脚本 (麒麟V10)
│   ├── security.sh        # 通用安全基线加固脚本 (CentOS/RHEL)
│   ├── BaseLineCheck.sh   # Linux 基线检查脚本
│   └── WindowsBaselineAssistant-v1.2.3.zip  # Windows 基线检查GUI工具
├── emergency/             # 应急响应
│   ├── LinuxCheck_V3.0.2.sh                 # Linux 应急处置/漏洞检测 v3.0.2
│   ├── LinuxCheck - 应急响应实用脚本修改版.sh  # LinuxCheck 修改版 v3.2
│   ├── AutoIncidentResponse.py              # 自动化应急分析 (Python)
│   └── D-Eyes_1.3.0/                        # 绿盟D-Eyes应急响应工具
├── ops/                   # 日常运维
│   ├── AutoBanForNginx.sh   # Nginx异常IP自动封禁
│   ├── AutoCreateUser.sh    # 批量创建用户
│   ├── log_management.sh    # 日志管理与清理
│   ├── disk_cleanup.sh      # ★ 通用磁盘清理工具 (多系统适配)
│   └── NginxCheck_v1.0.1.sh # Nginx日志分析
└── docs/                  # 参考文档
    └── 差距分析小结报告.doc
```

---

## security/ — 安全基线加固

### security_kylin.sh ★ 主力脚本

**适配系统**: Kylin Linux Advanced Server V10 (Halberd)  
**等保标准**: GB/T 22239-2019 第三级  
**依据文档**: 宁夏卫健委全员人口信息系统等保差距分析报告

#### 功能列表（15项 + 恢复）

| 编号 | 命令 | 功能 | all执行 |
|------|------|------|---------|
| 1 | `password` | 密码策略加固 (复杂度/有效期/历史记录) | ✅ |
| 2 | `login` | 登录失败锁定 (pam_faillock) + 会话超时 (TMOUT) | ✅ |
| 3 | `ssh` | SSH安全加固 + Telnet禁用 | ⚠ 跳过 |
| 4 | `hosts` | 网络访问控制 (hosts.allow/deny) | ⚠ 跳过 |
| 5 | `users` | 三权分立用户 (系统/审计/安全管理员) | ✅ |
| 6 | `umask` | umask权限掩码 (0027) | ✅ |
| 7 | `audit` | 安全审计 (auditd规则 + 日志轮转保护) | ✅ |
| 8 | `history` | 历史命令清除 (HISTSIZE=0) | ✅ |
| 9 | `fileperm` | 关键文件权限加固 | ✅ |
| 10 | `kernel` | 内核安全参数 (sysctl) | ✅ |
| 11 | `services` | 不安全服务检查与关闭 | ✅ |
| 12 | `aide` | AIDE完整性校验 (精简模式) | ✅ |
| 13 | `accounts` | 多余/过期/空密码账户清理 | ✅ |
| 14 | `backup` | 配置数据自动备份 | ✅ |
| 15 | `report` | 安全状态检查报告 (txt/md/docx) | ✅ |
| - | `restore` | 从备份恢复配置 | - |

> ⚠ 第3/4项可能导致SSH断连，`all` 一键执行时自动跳过，需从菜单单独选择。

#### 使用方法

```bash
# 查看帮助
bash security_kylin.sh --help

# 交互式菜单
bash security_kylin.sh

# 一键加固（安全，跳过SSH/hosts）
bash security_kylin.sh all

# 单项执行
bash security_kylin.sh password
bash security_kylin.sh ssh         # 会二次确认

# 生成检查报告
bash security_kylin.sh report          # 全部格式 (txt+md+docx)
bash security_kylin.sh report md       # 仅Markdown
bash security_kylin.sh report docx     # 仅Word文档

# 恢复配置
bash security_kylin.sh restore         # 交互式选择备份
bash security_kylin.sh restore 20260416_155137  # 指定时间点
```

#### 输出路径

| 类型 | 路径 |
|------|------|
| 检查报告 | `/root/security_reports/security_check_<时间戳>.[txt\|md\|docx]` |
| 执行日志 | `/var/log/security_harden.log` |
| 配置备份 | `/root/security_backup/<时间戳>/` (保留完整目录结构) |
| 密码文件 | `/root/security_backup/<时间戳>/passwords.txt` |

#### 推荐流程

```
1. bash security_kylin.sh all              # 一键加固 13 项
2. 用 sysadmin 用户测试 SSH 登录
3. bash security_kylin.sh ssh              # SSH加固
4. bash security_kylin.sh hosts            # hosts访问控制
5. bash security_kylin.sh report           # 生成报告留存
```

### security.sh

通用版安全基线加固脚本（CentOS/RHEL），`security_kylin.sh` 的前身。

### BaseLineCheck.sh

Linux 安全基线检查脚本，仅检查不修改，输出检查报告。

### WindowsBaselineAssistant-v1.2.3.zip

Windows 基线安全检查 GUI 工具。

---

## emergency/ — 应急响应

### LinuxCheck_V3.0.2.sh

Linux 应急处置/信息搜集/漏洞检测工具，覆盖 13 类 70+ 项检查：

- 基础配置、网络流量、任务计划、环境变量
- 用户信息、Services、bash 检查
- 恶意文件、内核 Rootkit、SSH
- Webshell、挖矿检测、供应链投毒
- 服务器风险、Docker 权限

### LinuxCheck - 应急响应实用脚本修改版.sh

LinuxCheck v3.2 修改版，在原版基础上增强了检查项。

### AutoIncidentResponse.py

Python 自动化应急分析工具（v1.0），通过 SSH 远程连接执行检查：

- 系统基本信息、异常进程定位
- 系统命令篡改检测、启动项检查
- 可疑历史命令、非系统用户检查
- crontab 定时任务、近三天文件修改
- 特权用户检查、secure 日志分析

### D-Eyes_1.3.0/

绿盟科技应急响应工具，支持 Linux 和 Windows。  
仓库: [github.com/m-sec-org/d-eyes](https://github.com/m-sec-org/d-eyes)

---

## ops/ — 日常运维

| 脚本 / 目录 | 功能 | 亮点 |
|---|---|---|
| `disk_cleanup.sh` | 通用磁盘清理工具 | ★ 风险分级，`--all` 默认安全 |
| `Linux_Auto_Inspection/` | Linux 服务器一键巡检 | ★ v2.5，17 类 25+ 维度，HTML 报告 |
| `Win_Multi_Inspection/` | Windows 多机巡检 | ★ CIM 远程采集，HTML + .docx 报告 |
| `NginxCheck_v1.0.1.sh` | Nginx 日志分析 | 访问量 / 异常请求 / IP 排行 |
| `AutoBanForNginx.sh` | 异常 IP 自动封禁 | iptables + Nginx 日志联动 |
| `AutoCreateUser.sh` | 批量创建用户 | 自动生成密码，结果保存到 `user.info` |
| `log_management.sh` | 日志管理与清理 | 定时自动清空 + 大小统计 |
| `Checklist/` | 安全检查清单脚本 | Linux `linux_inspect.sh` / Windows PowerShell |

### Linux_Auto_Inspection/ ★

**Linux 服务器一键巡检脚本** — 纯 Bash 编写，零依赖，自动生成结构化 HTML 巡检报告。

```bash
# 快速模式（推荐日常巡检，约 8-15 秒）
./linux_inspect.sh --fast

# 完整巡检（含联网更新检查 + SSL + 大文件扫描）
./linux_inspect.sh

# JSON 输出（对接 Prometheus / 监控平台）
./linux_inspect.sh -f json -o /tmp/inspect.json
```

覆盖 17 大类 25+ 项检查：基本信息 / CPU&负载 / 内存 / 磁盘 / 大文件 / 文件描述符 / 网络 / 进程 / 服务状态（40+）/ Docker-Podman / 定时任务 / 安全检查（SSH/账户/密码/SUID/登录）/ 内核参数（13项）/ 系统更新（6套包管理器）/ SSL证书 / 系统日志 / 总体建议。

兼容 Rocky/RHEL/CentOS/Ubuntu/Debian/Kylin/SUSE/Arch/Alpine/Gentoo。Exit code: 0=正常, 1=警告, 2=严重。

详细文档：[ops/Linux_Auto_Inspection/README.md](ops/Linux_Auto_Inspection/README.md)

### Win_Multi_Inspection/ ★

**多台 Windows 服务器一键巡检** — PowerShell CIM 远程采集，HTML + .docx 报告。

```powershell
# 从主机列表文件巡检
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt

# 指定凭据（跨域/工作组）
$cred = Get-Credential
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -Credential $cred

# 只生成 HTML（未安装 Word 时）
.\Multi-Server-Inspection.ps1 -Servers @('dc01','dc02') -NoWord
```

支持 WinRM (5985) 和 DCOM (135) 双协议，自动回退；PS 4.0+ 兼容（顺序执行），PS 7+ 并行 Job（`ThrottleLimit` 可调）。

详细文档：[ops/Win_Multi_Inspection/README.md](ops/Win_Multi_Inspection/README.md)

### disk_cleanup.sh ★ 通用磁盘清理工具

**适配系统**: CentOS 7/8/9 · RHEL/Rocky/AlmaLinux · Ubuntu 18-24 · Debian 10-12 · 麒麟 Kylin V10 · 华为 EulerOS / openEuler · 龙蜥 Anolis · 统信 UOS

#### 设计理念

按风险等级分级清理，**`--all` 默认仅执行安全 + 中危项**，对涉及 Docker 镜像删除、旧内核卸载等高危操作，必须显式通过 `--include-*` 开关启用，避免一次性误删可用资源。

| 等级 | 模块 | --all 执行 | 备注 |
|------|------|-----------|------|
| 🟢 安全 | 包缓存 (yum/dnf/apt) | ✅ | |
| 🟢 安全 | systemd journal (vacuum) | ✅ | 默认保留 200M / 30 天 |
| 🟢 安全 | /var/log 旧日志 (.gz/.[0-9]) | ✅ | 默认 >30 天 |
| 🟢 安全 | nginx/httpd/mysql 等应用日志 | ✅ | |
| 🟢 安全 | /tmp · /var/tmp | ✅ | 保留系统目录 |
| 🟢 安全 | coredump (/var/lib/systemd/coredump · /var/crash) | ✅ | |
| 🟢 安全 | 用户级缓存 (~/.cache · npm · composer · maven) | ✅ | |
| 🟢 安全 | 孤立包 / 未使用依赖 | ✅ | |
| 🟢 安全 | snap 旧版本 (保留 2 个修订) | ✅ | |
| 🟡 中危 | Docker 容器 / 网络 / 构建缓存 / dangling 镜像 | ✅ | 不删可用镜像 |
| 🟡 中危 | Podman / containerd (crictl) | ✅ | |
| 🔴 高危 | Docker 全部未使用镜像 | ❌ 跳过 | 需 `--include-docker-images` |
| 🔴 高危 | 旧内核 (保留当前+1) | ❌ 跳过 | 需 `--include-old-kernels` |
| 🔴 高危 | 家目录 >100M 大文件扫描 | ❌ 跳过 | 需 `--include-home-large` (仅列出) |

#### 使用方法

```bash
# 查看完整帮助
bash disk_cleanup.sh --help

# 强烈推荐: 首次使用先 dry-run 查看将清理什么
sudo bash disk_cleanup.sh --all --dry-run

# 安全一键清理 (跳过 Docker 镜像 / 旧内核, 不会误删)
sudo bash disk_cleanup.sh --all --yes

# 一键清理 + Docker 全镜像
sudo bash disk_cleanup.sh --all --include-docker-images --yes

# 一键清理 + Docker 镜像 + 旧内核
sudo bash disk_cleanup.sh --all --include-docker-images --include-old-kernels

# 单项执行
sudo bash disk_cleanup.sh journal              # 只清 journal
sudo bash disk_cleanup.sh --journal-keep 500M journal
sudo bash disk_cleanup.sh docker               # Docker 安全清理 (不动可用镜像)
sudo bash disk_cleanup.sh kernel               # 等价 --include-old-kernels kernel
sudo bash disk_cleanup.sh dockerimg            # 等价 --include-docker-images dockerimg

# 交互菜单
sudo bash disk_cleanup.sh
```

#### 单项命令一览

| 命令 | 功能 | 风险 |
|------|------|------|
| `pkg`        | 清理 yum/dnf/apt 缓存 | 🟢 |
| `orphan`     | 清理孤立包/未使用依赖 | 🟢 |
| `journal`    | 清理 systemd journal | 🟢 |
| `varlog`     | 清理 /var/log 轮转日志 | 🟢 |
| `applog`     | 清理 nginx/httpd/mysql 等 | 🟢 |
| `tmp`        | 清理 /tmp 与 /var/tmp | 🟢 |
| `coredump`   | 清理 coredump | 🟢 |
| `usercache`  | 清理用户缓存 | 🟢 |
| `snap`       | 清理 snap 旧版本 | 🟢 |
| `docker`     | Docker 安全清理 | 🟡 |
| `podman`     | Podman 清理 | 🟡 |
| `containerd` | containerd 镜像清理 | 🟡 |
| `dockerimg`  | Docker 全部未使用镜像 | 🔴 |
| `kernel`     | 删除旧内核 | 🔴 |
| `scanhome`   | 扫描家目录大文件 | 🟢 (仅列出) |
| `all`        | 一键清理 (跳过 🔴) | 综合 |

#### 关键参数

| 参数 | 说明 | 默认 |
|------|------|------|
| `--dry-run` | 试运行, 不实际删除 | off |
| `-y, --yes` | 跳过所有确认提示 | off |
| `--include-docker-images` | 允许删除全部未使用 Docker 镜像 | off |
| `--include-old-kernels` | 允许删除旧内核 | off |
| `--include-home-large` | 允许扫描家目录大文件 | off |
| `--journal-keep <SIZE>` | journal 保留量 | 200M |
| `--log-days <N>` | /var/log 旧日志保留天数 | 30 |
| `--tmp-days <N>` | /tmp 文件保留天数 | 7 |
| `--vartmp-days <N>` | /var/tmp 文件保留天数 | 30 |
| `--target-disk <PATH>` | 容量对比的挂载点 | / |

#### 输出与日志

| 类型 | 路径 |
|------|------|
| 执行日志 | `/var/log/disk_cleanup.log` (权限 600) |
| 屏幕输出 | 彩色日志, 含 INFO/OK/WARN/ERR/DRY 五级 |
| 容量对比 | 启动/结束各打印一次目标盘 (默认 `/`) 使用率 |

#### 安全机制

- **`--all` 默认安全**: 不会删除任何可用 Docker 镜像、不会删除任何内核
- **dry-run 优先**: 全模块支持试运行, 输出 `DRY-RUN: <将执行的命令>`, 不做实际改动
- **二次确认**: Docker volume / 大日志截断 / 旧内核删除等敏感操作均会提示, `-y` 可跳过
- **路径白名单**: 不删除 `.X11-unix` / `systemd-private-*` / `snap-private-tmp` 等系统占位
- **xdev 隔离**: coredump/scanhome 使用 `-xdev`, 不跨文件系统
- **包名安全**: 旧内核包名比较使用 `grep -F` (字面匹配, 防 +/. 等元字符干扰)
- **数组传参**: 涉及外部输入的命令一律走 `run_argv` (数组), 避免 word-splitting

#### 推荐运维流程

```bash
# 月度例行清理
sudo bash disk_cleanup.sh --all --dry-run            # 1. 看看会清掉什么
sudo bash disk_cleanup.sh --all --yes                # 2. 执行安全清理
df -h /                                              # 3. 确认效果

# 紧急释放空间 (磁盘 >90%)
sudo bash disk_cleanup.sh --all --include-docker-images --yes
sudo bash disk_cleanup.sh --include-old-kernels kernel    # 谨慎: 重启验证

# 定时任务 (每周日凌晨 3 点)
0 3 * * 0 root /opt/ShellHub/ops/disk_cleanup.sh --all --yes >> /var/log/disk_cleanup.cron 2>&1
```

### AutoBanForNginx.sh

基于 iptables + Nginx 日志的异常 IP 自动封禁/解封：

```bash
# cron 定时任务
*/5 * * * * root /path/to/AutoBanForNginx.sh block     # 每5分钟封禁
0 */2 * * * root /path/to/AutoBanForNginx.sh unblock   # 每2小时解封
```

### AutoCreateUser.sh

一键批量创建用户并自动生成密码，结果保存到 `user.info`：

```bash
bash AutoCreateUser.sh user1 user2 user3
```

### log_management.sh

日志管理脚本：0 点和 12 点自动清空日志内容（保留文件），其他时间统计并记录各日志文件大小：

```bash
# cron 定时任务：每小时执行
0 * * * * /path/to/log_management.sh
```

### NginxCheck_v1.0.1.sh

Nginx 日志分析脚本（v1.0.1），统计访问量、异常请求、IP 排行等。

---

## 环境要求

| 脚本 | 系统要求 | 依赖 |
|------|---------|------|
| `Linux_Auto_Inspection/linux_inspect.sh` | Linux (Bash 4.0+) | 零依赖，root 权限建议 |
| `Win_Multi_Inspection/Multi-Server-Inspection.ps1` | Windows Server 2012 R2+ / PS 4.0+ | WinRM (5985) 或 DCOM (135) |
| `disk_cleanup.sh` | CentOS 7-9 / Ubuntu 18-24 / Debian / Kylin / Euler / Anolis / UOS | bash, coreutils (find/du/awk) |
| `disk_cleanup.sh` (孤立包-yum 系) | RHEL/CentOS 7 | `yum install yum-utils` (提供 package-cleanup) |
| `security_kylin.sh` | Kylin V10 / CentOS 7+ | bash, systemd |
| `security_kylin.sh` report docx | 同上 | Node.js + docx 模块 |
| `security_kylin.sh` aide | 同上 | aide (`yum install aide`) |
| `AutoIncidentResponse.py` | 任意 (远程执行) | Python 2, paramiko |
| 其他 .sh 脚本 | CentOS / RHEL / Kylin | bash |

## 许可

内部使用
