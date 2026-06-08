# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/)。

## [Unreleased]

### Added

- **初始化**，从 ops/Checklist/Windows/README.md v2.0 历史版本迁移至此

---

## [1.0] - 2026-06-08

### Added

- **`Multi-Server-Inspection.ps1`** — 多台 Windows 服务器 CPU / 内存 / 磁盘一键巡检脚本
  - **CIM 双协议连接**：先试 WSMan（WinRM 5985），失败自动回退 DCOM（兼容 Win Server 2012 R2+）
  - **并行 / 顺序自适应**：PowerShell 7+ 用 `Start-Job` + `ThrottleLimit`，PS 4.0 用顺序执行（避开 PSRP 序列化 bug）
  - **CPU 3 次采样取平均**：更稳定反映真实负载（非瞬时峰值）
  - **物理磁盘健康状态**：MSFT_PhysicalDisk WMI 类，报告 HDD/SSD/SCM/NVMe 类型 + 健康状态
  - **彩色进度条 HTML 报告**：多盘符紧凑列表、pill 状态徽章（正常/离线/CPU高/内存高/磁盘满）
  - **Exit code**：0 全部成功，1 部分失败，2 全部失败
  - **可指定 Credential**：支持跨域 / 工作组主机（`-Credential (Get-Credential)`）
  - **ICMP 快速预探**：不通的主机直接跳过，避免长时间 CIM 连接超时

- **`Convert-HtmlToDocx.ps1`** — HTML → Word .docx 转换（Word COM 自动化，零第三方依赖）
  - 自动补 UTF-8 BOM（解决 Word 中文乱码问题）
  - 保留 Word 锁文件（`~$*.docx`）自动清理

- **`servers.txt.example`** — 主机列表模板文件（FQDN / IP / NetBIOS 名均支持）

- **`.gitignore`** — 排除巡检报告（HTML/DOCX/MD）、真实主机列表（servers.txt）、微信预览文件、Word 临时锁文件

### 兼容性

| 环境 | 要求 |
|---|---|
| PowerShell | 4.0+（PS 4.0 用顺序执行，PS 7+ 用并行 Job） |
| 目标系统 | Windows Server 2012 R2+ / Windows 10+ |
| 目标机要求 | WinRM (5985) 或 DCOM (135 + 动态端口) |
| 网络 | 同域账户最简单，跨域/工作组需指定 `-Credential` |
| Word（可选） | 用于 HTML→DOCX 转换，未安装时用 `--NoWord` |