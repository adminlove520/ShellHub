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

### AutoBanForNginx.sh

基于 iptables + Nginx 日志的异常IP自动封禁/解封：

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

日志管理脚本：
- 0 点和 12 点自动清空日志内容（保留文件）
- 其他时间统计并记录各日志文件大小

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
| security_kylin.sh | Kylin V10 / CentOS 7+ | bash, systemd |
| security_kylin.sh report docx | 同上 | Node.js + docx 模块 |
| security_kylin.sh aide | 同上 | aide (`yum install aide`) |
| AutoIncidentResponse.py | 任意 (远程执行) | Python 2, paramiko |
| 其他 .sh 脚本 | CentOS / RHEL / Kylin | bash |

## 许可

内部使用
