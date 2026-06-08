# Windows 多机巡检

**多台 Windows 服务器 CPU / 内存 / 磁盘一键巡检** — 通过 CIM (WinRM/DCOM) 远程采集，输出彩色 HTML + .docx 报告。

[![PowerShell](https://img.shields.io/badge/PowerShell-4.0%2B-blue)](https://docs.microsoft.com/zh-cn/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows-orange)]()
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## 功能概览

```
============================================================
  Windows 本机巡检 (CPU / 内存 / 磁盘)
============================================================
目标主机数: 1
并行上限: 8
输出目录: D:\巡检报告

  [ 1/ 1] LAPTOP-SUNCTJEG            OK (8.6s)

采集耗时: 8.6 秒，共 1 条结果

正在生成 HTML 报告 ...
正在转换 DOCX ...
完成: D:\巡检报告\Inspection_20260608_173723.docx
```

---

## 快速开始

### 环境要求

- PowerShell 4.0+（PS 4.0 顺序执行，PS 7+ 并行 Job）
- 目标机开通 WinRM (5985) 或 DCOM (135 + 动态端口)
- 同域账户最简单，跨域/工作组需 `-Credential`

### 安装

```powershell
git clone https://github.com/adminlove520/ShellHub
cd ops/Win_Multi_Inspection
```

### 用法

```powershell
# ★ 默认单机巡检（自动采集本机，不需任何文件）
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt

# 多机巡检（每行一个主机名，# 开头为注释）
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt

# 单行命令指定多台主机
.\Multi-Server-Inspection.ps1 -Servers @('dc01','dc02','dfs01')

# 跨域/工作组指定凭据
$cred = Get-Credential
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -Credential $cred

# 调整并行上限（默认 8）
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -ThrottleLimit 4

# 只生成 HTML（未安装 Word 时使用）
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -NoWord

# 自定义输出目录
.\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -OutDir D:\Reports\20260608
```

---

## 参数说明

| 参数 | 说明 |
|---|---|
| `-Servers <string[]>` | 主机名/IP 数组，与 `-ServerListFile` 二选一 |
| `-ServerListFile <string>` | 主机列表文件路径，每行一个，`#` 开头为注释。<br>文件不存在时自动切换为**单机本机巡检** |
| `-Credential <PSCredential>` | 凭据（跨域/工作组必填）：`Get-Credential` |
| `-OutDir <string>` | 输出目录（默认脚本所在目录） |
| `-ThrottleLimit <int>` | 并行 Job 上限（默认 8） |
| `-NoWord` | 只生成 HTML，跳过 Word .docx 转换 |

---

## 检查维度

| 维度 | 说明 |
|---|---|
| **基本信息** | 主机名、操作系统 (Build)、启动时间、运行天数 |
| **CPU** | 型号、核心数/逻辑处理器数、3 次采样负载平均值 |
| **内存** | 总容量、已用、可用、使用率 |
| **逻辑磁盘** | 每盘符：容量、可用、已用、使用率（带彩色进度条） |
| **物理磁盘** | 型号、介质类型（HDD/SSD/NVMe）、总线类型、健康状态 |
| **状态** | 离线 / 正常 / CPU高 / 内存高 / 磁盘满（pill 徽章） |

---

## 输出文件

| 文件 | 说明 |
|---|---|
| `Inspection_YYYYMMDD_HHmmss.html` | 主报告（浏览器打开，可打印为 PDF） |
| `Inspection_YYYYMMDD_HHmmss.docx` | Word 文档（通过 Word COM 自动转换） |

报告包含：

- **汇总表格** — 所有主机 CPU / 内存 / 磁盘使用率一览，pill 状态徽章
- **主机明细卡片** — 每台主机的 3 次 CPU 采样曲线、内存条、磁盘条、硬件详情

---

## 批量巡检示例

```powershell
# 定时任务：每周一早 8 点巡检
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9am
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File D:\Scripts\Multi-Server-Inspection.ps1 -ServerListFile D:\Scripts\servers.txt -OutDir D:\Reports'
Register-ScheduledTask -TaskName 'WeeklyServerInspection' -Trigger $trigger -Action $action -RunLevel Highest
```

---

## 目录结构

```
Win_Multi_Inspection/
├── Multi-Server-Inspection.ps1   # 主脚本（多机巡检）
├── Convert-HtmlToDocx.ps1       # HTML→Word 转换工具
├── servers.txt.example           # 主机列表模板
├── CHANGELOG.md                  # 版本更新日志
├── README.md                     # 项目说明（本文件）
└── .gitignore                    # 排除敏感文件
```

---

## 更新日志

完整版本历史见 [CHANGELOG.md](CHANGELOG.md)。

---

## License

[MIT License](LICENSE)