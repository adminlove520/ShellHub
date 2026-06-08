<#
.SYNOPSIS
    多台 Windows 服务器 CPU / 内存 / 磁盘 一键巡检 → Word 报告
.DESCRIPTION
    并行通过 CIM (WinRM/DCOM 回退) 采集远程主机指标，输出汇总 HTML + .docx 报告。
    兼容 PowerShell 4.0+ 和 Windows Server 2012 R2+。
.PARAMETER Servers
    主机名 / IP 数组。例: -Servers @('s1','s2','10.0.0.3')
.PARAMETER ServerListFile
    每行一个主机名的 txt 文件，与 -Servers 二选一。空行和以 # 开头的行忽略。
.PARAMETER Credential
    凭据。默认用当前账户。跨域或工作组需指定：-Credential (Get-Credential)
.PARAMETER OutDir
    输出目录（默认脚本目录）。
.PARAMETER ThrottleLimit
    并行 job 上限（默认 8）。
.PARAMETER NoWord
    只生成 HTML，不调 Word 转 docx（没装 Word 时用）。
.EXAMPLE
    .\Multi-Server-Inspection.ps1 -Servers @('ad01','ad02','dfs01','ddc01','ddc02')
    .\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt
    .\Multi-Server-Inspection.ps1 -ServerListFile .\servers.txt -Credential (Get-Credential VDESK\admin)
.NOTES
    需要被巡检机开通 WinRM (5985) 或 DCOM (135 + 动态)。同域账户最简单。
#>

[CmdletBinding(DefaultParameterSetName='List')]
param(
    [Parameter(ParameterSetName='Inline', Mandatory=$true)]
    [string[]] $Servers,
    [Parameter(ParameterSetName='File', Mandatory=$true)]
    [string]   $ServerListFile,
    [System.Management.Automation.PSCredential] $Credential,
    [string] $OutDir,
    [int]    $ThrottleLimit = 8,
    [switch] $NoWord
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { chcp 65001 > $null } catch {}

# ==================== 主机列表 ====================
if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path $ServerListFile)) { throw "找不到列表文件: $ServerListFile" }
    $Servers = Get-Content $ServerListFile | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() }
}
$Servers = $Servers | Where-Object { $_ } | Select-Object -Unique
if (-not $Servers -or $Servers.Count -eq 0) { throw "主机列表为空" }

if (-not $OutDir) {
    $OutDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Write-Host ('=' * 60)
Write-Host "  Windows 多机巡检 (CPU / 内存 / 磁盘)"
Write-Host ('=' * 60)
Write-Host "目标主机数: $($Servers.Count)" -ForegroundColor Cyan
Write-Host "并行上限: $ThrottleLimit"
Write-Host "输出目录: $OutDir`n"

# ==================== 采集函数（在 Job 里跑） ====================
$collectBlock = {
    param($Target, $Cred)

    $r = [ordered]@{
        target    = $Target
        ok        = $false
        error     = ''
        hostname  = ''
        os        = ''
        uptime    = ''
        boot_time = ''
        cpu_name  = ''
        cpu_cores = 0
        cpu_logical = 0
        cpu_load_pct = 0
        cpu_load_samples = @()
        mem_total_gb = 0
        mem_used_gb  = 0
        mem_free_gb  = 0
        mem_pct      = 0
        disks    = @()
        physical = @()
    }

    # 1. ICMP 快速预探
    if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet -EA SilentlyContinue)) {
        $r.error = 'ICMP 不通'
        return [pscustomobject]$r
    }

    # 2. 建立 CIM Session：先试 WSMan（WinRM 5985），失败回退 DCOM (Win32 旧版)
    $cimSession = $null
    $sessionOpts = $null
    foreach ($proto in @('Wsman','Dcom')) {
        try {
            $sessionOpts = New-CimSessionOption -Protocol $proto
            $params = @{
                ComputerName  = $Target
                SessionOption = $sessionOpts
                OperationTimeoutSec = 25
                ErrorAction   = 'Stop'
            }
            if ($Cred) { $params.Credential = $Cred }
            $cimSession = New-CimSession @params
            if ($cimSession) { break }
        } catch {
            $cimSession = $null
            $lastErr = $_.Exception.Message
        }
    }
    if (-not $cimSession) {
        $r.error = "CIM 连接失败: $lastErr"
        return [pscustomobject]$r
    }

    try {
        # 3. OS / 主机名 / 内存
        $os = Get-CimInstance Win32_OperatingSystem -CimSession $cimSession -EA Stop
        $r.hostname = $os.CSName
        $r.os = "$($os.Caption) (Build $($os.BuildNumber))"
        $boot = $os.LastBootUpTime
        if ($boot) {
            $r.boot_time = $boot.ToString('yyyy-MM-dd HH:mm:ss')
            $delta = (Get-Date) - $boot
            $r.uptime = "$($delta.Days)天 $($delta.Hours)时 $($delta.Minutes)分"
        }
        $r.mem_total_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $r.mem_free_gb  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $r.mem_used_gb  = [math]::Round($r.mem_total_gb - $r.mem_free_gb, 2)
        $r.mem_pct      = if ($r.mem_total_gb -gt 0) { [math]::Round($r.mem_used_gb / $r.mem_total_gb * 100, 1) } else { 0 }

        # 4. CPU
        $cpus = @(Get-CimInstance Win32_Processor -CimSession $cimSession -EA Stop)
        if ($cpus.Count -gt 0) {
            $r.cpu_name = $cpus[0].Name.Trim()
            if ($cpus.Count -gt 1) { $r.cpu_name = "$($r.cpu_name) × $($cpus.Count)" }
            $r.cpu_cores   = ($cpus | Measure-Object NumberOfCores -Sum).Sum
            $r.cpu_logical = ($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum
        }
        # CPU 负载：连采 3 次取平均（每次间隔 1 秒），更稳定
        $samples = @()
        for ($i = 0; $i -lt 3; $i++) {
            $procs = Get-CimInstance Win32_Processor -CimSession $cimSession -EA SilentlyContinue
            if ($procs) {
                $avg = ($procs | Measure-Object LoadPercentage -Average).Average
                if ($null -ne $avg) { $samples += [int][math]::Round($avg) }
            }
            if ($i -lt 2) { Start-Sleep -Seconds 1 }
        }
        $r.cpu_load_samples = $samples
        $r.cpu_load_pct = if ($samples.Count -gt 0) { [int][math]::Round(($samples | Measure-Object -Average).Average) } else { 0 }

        # 5. 逻辑磁盘
        $logical = Get-CimInstance Win32_LogicalDisk -CimSession $cimSession -Filter 'DriveType=3' -EA SilentlyContinue
        foreach ($d in $logical) {
            $totalGB = if ($d.Size) { [math]::Round($d.Size / 1GB, 2) } else { 0 }
            $freeGB  = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 2) } else { 0 }
            $usedGB  = [math]::Round($totalGB - $freeGB, 2)
            $pct     = if ($totalGB -gt 0) { [math]::Round($usedGB / $totalGB * 100, 1) } else { 0 }
            $r.disks += [ordered]@{
                drive = $d.DeviceID
                label = if ($d.VolumeName) { $d.VolumeName } else { '' }
                fs    = $d.FileSystem
                total = $totalGB
                free  = $freeGB
                used  = $usedGB
                pct   = $pct
            }
        }

        # 6. 物理磁盘（如果支持 Storage Module）
        try {
            $phys = Get-CimInstance -CimSession $cimSession -ClassName MSFT_PhysicalDisk -Namespace 'root\Microsoft\Windows\Storage' -EA Stop
            foreach ($p in $phys) {
                $r.physical += [ordered]@{
                    name   = $p.FriendlyName
                    media  = switch ($p.MediaType) { 3 {'HDD'}; 4 {'SSD'}; 5 {'SCM'}; default {'未知'} }
                    bus    = switch ($p.BusType)   { 1 {'SCSI'}; 6 {'SATA'}; 7 {'iSCSI'}; 8 {'SAS'}; 11 {'SATA'}; 17 {'NVMe'}; default {'其他'} }
                    size   = if ($p.Size) { [math]::Round($p.Size / 1GB, 0) } else { 0 }
                    health = switch ($p.HealthStatus) { 0 {'健康'}; 1 {'警告'}; 2 {'不健康'}; default {'未知'} }
                }
            }
        } catch {}

        $r.ok = $true
    } catch {
        $r.error = "CIM 查询失败: $($_.Exception.Message)"
    } finally {
        if ($cimSession) { Remove-CimSession $cimSession -EA SilentlyContinue }
    }

    return [pscustomobject]$r
}

# ==================== 顺序执行（避开 PS 4.0 Start-Job 序列化 bug） ====================
Write-Host "开始顺序采集（PS 4.0 兼容模式，单次约 8~15 秒/台）..." -ForegroundColor Cyan
$startTime = Get-Date
$results = @()

# 兜底辅助函数
function New-EmptyResult([string]$T, [string]$Err) {
    [pscustomobject]@{
        target = $T; ok = $false; error = $Err
        hostname = ''; os = ''; uptime = ''; boot_time = ''
        cpu_name = ''; cpu_cores = 0; cpu_logical = 0
        cpu_load_pct = 0; cpu_load_samples = @()
        mem_total_gb = 0; mem_used_gb = 0; mem_free_gb = 0; mem_pct = 0
        disks = @(); physical = @()
    }
}

$total = $Servers.Count
$idx = 0
foreach ($target in $Servers) {
    $idx++
    $t0 = Get-Date
    Write-Host ("  [{0,2}/{1}] {2,-30}" -f $idx, $total, $target) -ForegroundColor Gray -NoNewline
    $r = $null
    try {
        # 直接在主进程调用 ScriptBlock，避开 Background Job 的 PSRP 序列化
        $r = & $collectBlock $target $Credential
    } catch {
        $r = New-EmptyResult $target ("采集异常: " + $_.Exception.Message)
    }
    if (-not $r) {
        $r = New-EmptyResult $target '采集函数无返回'
    }
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    if ($r.ok) {
        Write-Host (" OK ({0}s)" -f $secs) -ForegroundColor Green
    } else {
        $msg = if ($r.error) { $r.error } else { '未知失败' }
        Write-Host (" FAIL ({0}s) - {1}" -f $secs, $msg) -ForegroundColor Red
    }
    $results += $r
}

$elapsed = ((Get-Date) - $startTime).TotalSeconds
Write-Host "`n采集耗时: $([math]::Round($elapsed, 1)) 秒，共 $($results.Count) 条结果`n" -ForegroundColor Cyan

# ==================== HTML 生成 ====================
function Esc($s) {
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$s)
}
# 进度条单元格：根据百分比上不同色，右侧白底显示百分比
function PctCell($pct) {
    $color = if ($pct -lt 70) {'#34a853'} elseif ($pct -lt 90) {'#f9a825'} else {'#d93025'}
    "<div class=`"bar-wrap`"><div class=`"bar`"><div class=`"bar-fill`" style=`"width:$pct%;background:$color`"></div></div><span class=`"pct-text`" style=`"color:$color`">$pct%</span></div>"
}
function StatusBadge($r) {
    if (-not $r.ok) { return '<span class="pill pill-red">离线</span>' }
    $issues = @()
    if ($r.cpu_load_pct -ge 90) { $issues += 'CPU高' }
    if ($r.mem_pct -ge 90) { $issues += '内存高' }
    foreach ($d in $r.disks) { if ($d.pct -ge 90) { $issues += "$($d.drive)磁盘满" } }
    if ($issues.Count -eq 0) { '<span class="pill pill-green">正常</span>' }
    else { "<span class=`"pill pill-red`">$(Esc ($issues -join '/'))</span>" }
}
# 圆形图标 (SVG inline，Word/浏览器都能正确显示)
function MetaIcon($kind) {
    $svgs = @{
        'date' = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="18" height="16" rx="2"/><line x1="16" y1="3" x2="16" y2="7"/><line x1="8" y1="3" x2="8" y2="7"/><line x1="3" y1="11" x2="21" y2="11"/></svg>'
        'time' = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><polyline points="12,7 12,12 15.5,14.5"/></svg>'
        'host' = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="13" rx="1"/><line x1="8" y1="20" x2="16" y2="20"/><line x1="12" y1="17" x2="12" y2="20"/></svg>'
        'timer' = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="13" r="8"/><polyline points="12,9 12,13 15,15"/><line x1="9" y1="2" x2="15" y2="2"/></svg>'
        'user' = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8"/></svg>'
    }
    $svg = $svgs[$kind]
    if (-not $svg) { $svg = $svgs['host'] }
    "<div class=`"mi-icon`">$svg</div>"
}

$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$today = (Get-Date).ToString('yyyy-MM-dd')
$accountStr = if ($Credential) { $Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }
$sb = New-Object System.Text.StringBuilder

[void]$sb.Append(@"
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<title>Windows 多机巡检报告 - $today</title>
<style>
* { box-sizing: border-box; }
body { font-family: -apple-system,'微软雅黑','Microsoft YaHei','Segoe UI',sans-serif; font-size: 13px; color: #1f2937; line-height: 1.55; background: #f5f7fa; margin: 0; padding: 28px 40px; }

/* 页眉 */
.page-head { display: flex; justify-content: space-between; align-items: flex-end; margin-bottom: 20px; padding: 0 4px; }
.page-head h1 { font-size: 26px; margin: 0; color: #111827; font-weight: 700; letter-spacing: -0.3px; }
.page-head .head-ts { font-size: 12px; color: #6b7280; }
.page-head .head-ts b { color: #1f2937; font-weight: 600; margin-left: 4px; }

/* 卡片基础（白底 + 微阴影 + 圆角） */
.card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 22px 26px; margin: 12px 0; box-shadow: 0 1px 2px rgba(15,23,42,0.04); }

/* 元数据 grid (顶部 5 项 — 5 列等分) */
.meta-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px 20px; }
.mi { display: flex; align-items: center; gap: 12px; padding: 4px 0; min-width: 0; }
.mi-icon { width: 36px; height: 36px; border-radius: 50%; background: linear-gradient(135deg, #e8f0fe 0%, #dce8fc 100%); color: #1e3c72; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.mi-icon svg { width: 18px; height: 18px; }
.mi-text { min-width: 0; overflow: hidden; }
.mi-label { color: #6b7280; font-size: 11px; margin-bottom: 2px; }
.mi-value { color: #111827; font-weight: 600; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
@media (max-width: 1100px) { .meta-grid { grid-template-columns: repeat(2, 1fr); gap: 14px 28px; } }

/* 章节标题 */
.section { margin: 26px 4px 12px; display: flex; align-items: center; gap: 10px; }
.section::before { content: ''; display: inline-block; width: 4px; height: 18px; background: #2a5298; border-radius: 2px; }
.section h2 { margin: 0; font-size: 16px; font-weight: 700; color: #111827; letter-spacing: 0.2px; }

/* 主表格 */
table.grid { width: 100%; border-collapse: separate; border-spacing: 0; background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden; font-size: 12.5px; box-shadow: 0 1px 2px rgba(15,23,42,0.04); }
table.grid thead th { background: #1e3c72; color: #fff; font-weight: 600; text-align: left; padding: 13px 14px; font-size: 12.5px; letter-spacing: 0.2px; }
table.grid thead th:first-child { padding-left: 18px; }
table.grid thead th:last-child { padding-right: 18px; }
table.grid tbody td { padding: 12px 14px; border-top: 1px solid #eef0f3; vertical-align: middle; color: #1f2937; }
table.grid tbody td:first-child { padding-left: 18px; color: #6b7280; font-weight: 500; }
table.grid tbody td:last-child { padding-right: 18px; }
table.grid tbody tr:first-child td { border-top: none; }
table.grid tbody tr:hover { background: #fafbfc; }
table.grid .num { text-align: right; font-variant-numeric: tabular-nums; }
table.grid .small { font-size: 11px; color: #6b7280; margin-top: 2px; }

/* KV 表（详情面板基本信息） */
table.kv { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 12.5px; }
table.kv td { padding: 9px 12px; border-bottom: 1px solid #f1f4f8; vertical-align: middle; }
table.kv tr:last-child td { border-bottom: none; }
table.kv td:first-child { color: #6b7280; font-weight: 500; width: 80px; padding-left: 0; }
table.kv td:nth-child(2) { color: #111827; font-weight: 500; }

/* 进度条（紧凑水平：[bar][%]） */
.bar-wrap { display: flex; align-items: center; gap: 10px; min-width: 140px; }
.bar { flex: 1; background: #eef0f3; height: 8px; border-radius: 4px; overflow: hidden; min-width: 80px; }
.bar-fill { height: 100%; border-radius: 4px; }
.pct-text { font-weight: 700; font-size: 12.5px; font-variant-numeric: tabular-nums; min-width: 44px; text-align: right; }

/* 总览表里磁盘列：多盘符紧凑列表 */
.disk-list { display: flex; flex-direction: column; gap: 4px; }
.disk-item { display: flex; align-items: center; gap: 8px; font-size: 11.5px; }
.disk-item .drv-label { font-weight: 700; color: #374151; min-width: 26px; }
.disk-item .mini-bar { flex: 1; background: #eef0f3; height: 5px; border-radius: 3px; overflow: hidden; min-width: 50px; }
.disk-item .mini-fill { height: 100%; border-radius: 3px; }
.disk-item .mini-pct { color: #4b5563; font-weight: 600; font-variant-numeric: tabular-nums; min-width: 38px; text-align: right; }

/* 状态徽章 — 软色调 + 边框 */
.pill { display: inline-block; padding: 3px 10px; border-radius: 4px; font-size: 11.5px; font-weight: 600; white-space: nowrap; line-height: 1.5; }
.pill-green { background: #e6f4ea; color: #1e7e34; border: 1px solid #b4dec1; }
.pill-orange { background: #fef3c7; color: #92400e; border: 1px solid #fcd34d; }
.pill-red { background: #fde2e2; color: #991b1b; border: 1px solid #fca5a5; }
.pill-gray { background: #f3f4f6; color: #4b5563; border: 1px solid #d1d5db; }
.pill-solid-orange { display: inline-block; background: #f59e0b; color: #fff; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 700; }
.pill-solid-red { display: inline-block; background: #dc2626; color: #fff; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 700; }
.pill-solid-gray { display: inline-block; background: #6b7280; color: #fff; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 700; }

/* 主机明细卡片 */
.host-card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 22px 26px; margin: 12px 0; box-shadow: 0 1px 2px rgba(15,23,42,0.04); }
.host-card .host-title { font-size: 15px; font-weight: 700; color: #1e3c72; margin: 0 0 16px; padding-bottom: 12px; border-bottom: 1px solid #eef0f3; }
.host-grid { display: grid; grid-template-columns: 1fr 1fr 1.3fr; gap: 24px; }
@media (max-width: 1100px) { .host-grid { grid-template-columns: 1fr; gap: 16px; } }
.sub-panel { min-width: 0; }
.sub-panel h4 { font-size: 12.5px; font-weight: 700; color: #374151; margin: 0 0 12px; padding-left: 10px; border-left: 3px solid #2a5298; letter-spacing: 0.3px; }

/* 资源使用：单行水平 [label][bar][%] */
.res-row { padding: 10px 0; border-bottom: 1px solid #f1f4f8; }
.res-row:last-child { border-bottom: none; }
.res-row .res-head { display: flex; align-items: center; gap: 10px; }
.res-row .res-label { font-size: 12px; color: #4b5563; font-weight: 600; min-width: 70px; }
.res-row .res-bar { flex: 1; background: #eef0f3; height: 8px; border-radius: 4px; overflow: hidden; min-width: 60px; }
.res-row .res-bar > div { height: 100%; border-radius: 4px; }
.res-row .res-pct { font-size: 13px; font-weight: 700; min-width: 48px; text-align: right; font-variant-numeric: tabular-nums; }
.res-row .res-sub { font-size: 11px; color: #6b7280; margin-top: 4px; padding-left: 80px; }

/* 磁盘小表 */
.disk-table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 11.5px; }
.disk-table th { color: #6b7280; font-weight: 600; text-align: left; padding: 8px 6px; border-bottom: 1px solid #e5e7eb; background: transparent; font-size: 11px; letter-spacing: 0.2px; text-transform: uppercase; }
.disk-table td { padding: 9px 6px; border-bottom: 1px solid #f1f4f8; vertical-align: middle; }
.disk-table tr:last-child td { border-bottom: none; }
.disk-table .drv { font-weight: 700; color: #1e3c72; }
.disk-table .num-cell { font-variant-numeric: tabular-nums; color: #4b5563; font-size: 11.5px; }

/* 存储设备底部表 */
.storage-section { margin-top: 18px; }
.storage-section h4 { font-size: 12.5px; font-weight: 700; color: #374151; margin: 0 0 12px; padding-left: 10px; border-left: 3px solid #2a5298; letter-spacing: 0.3px; }

code { font-family: Consolas,'Courier New',monospace; background:#f1f4f8; padding:1px 5px; border-radius:3px; font-size:12px; color:#1f2937; }

.intro-text { color: #4b5563; font-size: 12.5px; line-height: 1.7; margin: 0 0 14px; }
.intro-text strong { color: #1e3c72; font-weight: 600; }
.intro-divider { height: 1px; background: #eef0f3; margin: 0 0 18px; }

/* 目录 */
.toc-card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 18px 24px; margin: 12px 0; box-shadow: 0 1px 2px rgba(15,23,42,0.04); }
.toc-card .toc-title { font-size: 13px; font-weight: 700; color: #1e3c72; margin: 0 0 12px; padding-left: 10px; border-left: 3px solid #2a5298; letter-spacing: 1px; }
.toc-list { list-style: none; padding: 0; margin: 0; }
.toc-list > li { padding: 5px 0; font-size: 13px; }
.toc-list > li > a { color: #1f2937; text-decoration: none; font-weight: 600; border-bottom: 1px dotted transparent; }
.toc-list > li > a:hover { color: #1e3c72; border-bottom-color: #2a5298; }
.toc-sub { list-style: none; padding: 6px 0 4px 18px; margin: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 4px 18px; }
.toc-sub > li > a { color: #6b7280; text-decoration: none; font-size: 12px; font-weight: 400; display: flex; gap: 8px; padding: 3px 0; border-bottom: 1px dotted transparent; }
.toc-sub > li > a:hover { color: #1e3c72; border-bottom-color: #d1d5db; }
.toc-sub .toc-num { color: #9ca3af; font-variant-numeric: tabular-nums; min-width: 28px; }
.toc-sub .toc-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; align-self: center; }

.footer-note { margin-top: 28px; color: #9ca3af; font-size: 11px; text-align: center; padding-top: 16px; border-top: 1px solid #e5e7eb; }

@media print { body { background: #fff; padding: 10mm; } .card, .host-card, table.grid { box-shadow: none; } }
</style></head><body>

<div class="page-head">
  <h1>Windows 多机巡检报告</h1>
  <div class="head-ts">报告生成时间:<b>$ts</b></div>
</div>

<div class="card">
  <p class="intro-text">通过 <strong>WinRM / DCOM</strong> 远程采集 Windows 服务器的 CPU、内存、磁盘指标，自动评估资源风险（≥90% 高危 / ≥70%~80% 中等），生成 HTML + Word 巡检报告。</p>
  <div class="intro-divider"></div>
  <div class="meta-grid">
    <div class="mi">$(MetaIcon 'date')<div class="mi-text"><div class="mi-label">巡检日期</div><div class="mi-value">$today</div></div></div>
    <div class="mi">$(MetaIcon 'time')<div class="mi-text"><div class="mi-label">巡检时间</div><div class="mi-value">$($ts.Substring(11))</div></div></div>
    <div class="mi">$(MetaIcon 'host')<div class="mi-text"><div class="mi-label">主机数</div><div class="mi-value">$($Servers.Count) 台</div></div></div>
    <div class="mi">$(MetaIcon 'timer')<div class="mi-text"><div class="mi-label">采集耗时</div><div class="mi-value">$([math]::Round($elapsed,1)) 秒</div></div></div>
    <div class="mi">$(MetaIcon 'user')<div class="mi-text"><div class="mi-label">采集账户</div><div class="mi-value">$(Esc $accountStr)</div></div></div>
  </div>
</div>
"@)

# === 目录 ===
[void]$sb.Append("<div class=`"toc-card`">`n<div class=`"toc-title`">目  录</div>`n<ul class=`"toc-list`">`n")
[void]$sb.Append("<li><a href=`"#sec1`">一、总览</a></li>`n")
[void]$sb.Append("<li><a href=`"#sec2`">二、风险汇总</a></li>`n")
[void]$sb.Append("<li><a href=`"#sec3`">三、各主机明细</a>`n")
[void]$sb.Append("<ul class=`"toc-sub`">`n")
$tocIdx = 1
foreach ($r in ($results | Sort-Object target)) {
    $tocTitle = if ($r.hostname) { $r.hostname } else { $r.target }
    # 健康状态点
    $dotColor = '#34a853'
    if (-not $r.ok) { $dotColor = '#dc2626' }
    elseif ($r.cpu_load_pct -ge 90 -or $r.mem_pct -ge 90) { $dotColor = '#dc2626' }
    elseif ($r.cpu_load_pct -ge 70 -or $r.mem_pct -ge 80) { $dotColor = '#f59e0b' }
    foreach ($d in $r.disks) {
        if ([double]$d.pct -ge 90) { $dotColor = '#dc2626' }
        elseif ([double]$d.pct -ge 80 -and $dotColor -eq '#34a853') { $dotColor = '#f59e0b' }
    }
    [void]$sb.Append("<li><a href=`"#host-$tocIdx`"><span class=`"toc-dot`" style=`"background:$dotColor`"></span><span class=`"toc-num`">3.$tocIdx</span>$(Esc $tocTitle)</a></li>`n")
    $tocIdx++
}
[void]$sb.Append("</ul>`n</li>`n</ul>`n</div>`n")

# === 总览表 ===
[void]$sb.Append("<div class=`"section`" id=`"sec1`"><h2>一、总览</h2></div>`n<table class=`"grid`">`n")
[void]$sb.Append("<thead><tr><th style=`"width:40px`">#</th><th style=`"min-width:160px`">主机</th><th>OS</th><th>运行时间</th><th style=`"width:170px`">CPU 负载</th><th style=`"width:170px`">内存使用</th><th style=`"min-width:200px`">磁盘使用</th><th style=`"width:80px`">状态</th></tr></thead><tbody>`n")
$idx = 1
foreach ($r in ($results | Sort-Object target)) {
    if (-not $r.ok) {
        [void]$sb.Append("<tr><td>$idx</td><td><b>$(Esc $r.target)</b></td><td colspan=`"5`" style=`"color:#d93025`">$(Esc $r.error)</td><td>$(StatusBadge $r)</td></tr>`n")
    } else {
        # 多盘符迷你进度条列表
        $diskListHtml = ''
        if ($r.disks.Count -gt 0) {
            $diskListHtml = '<div class="disk-list">'
            foreach ($d in $r.disks) {
                $pv = [double]$d.pct
                $dColor = if ($pv -lt 70) {'#34a853'} elseif ($pv -lt 90) {'#f59e0b'} else {'#dc2626'}
                $diskListHtml += "<div class=`"disk-item`"><span class=`"drv-label`">$(Esc $d.drive)</span><div class=`"mini-bar`"><div class=`"mini-fill`" style=`"width:$pv%;background:$dColor`"></div></div><span class=`"mini-pct`">$pv%</span></div>"
            }
            $diskListHtml += '</div>'
        } else {
            $diskListHtml = '<span style="color:#9ca3af;font-size:11.5px">无</span>'
        }
        [void]$sb.Append("<tr>")
        [void]$sb.Append("<td>$idx</td>")
        [void]$sb.Append("<td><b style=`"color:#111827`">$(Esc $r.hostname)</b><div class=`"small`">$(Esc $r.target)</div></td>")
        [void]$sb.Append("<td><div style=`"font-size:12px`">$(Esc $r.os)</div></td>")
        [void]$sb.Append("<td>$(Esc $r.uptime)</td>")
        [void]$sb.Append("<td>$(PctCell $r.cpu_load_pct)</td>")
        [void]$sb.Append("<td>$(PctCell $r.mem_pct)<div class=`"small`">$($r.mem_used_gb) / $($r.mem_total_gb) GB</div></td>")
        [void]$sb.Append("<td>$diskListHtml</td>")
        [void]$sb.Append("<td>$(StatusBadge $r)</td>")
        [void]$sb.Append("</tr>`n")
    }
    $idx++
}
[void]$sb.Append("</tbody></table>`n")

# === 风险汇总 ===
$alerts = @()
foreach ($r in $results) {
    if (-not $r.ok) { $alerts += [pscustomobject]@{host=$r.target; level='离线'; item=$r.error; value=''}; continue }
    if ($r.cpu_load_pct -ge 90) { $alerts += [pscustomobject]@{host=$r.hostname; level='高'; item='CPU 持续高负载'; value="$($r.cpu_load_pct)%"} }
    elseif ($r.cpu_load_pct -ge 70) { $alerts += [pscustomobject]@{host=$r.hostname; level='中'; item='CPU 负载偏高'; value="$($r.cpu_load_pct)%"} }
    if ($r.mem_pct -ge 90) { $alerts += [pscustomobject]@{host=$r.hostname; level='高'; item='内存使用率过高'; value="$($r.mem_pct)%"} }
    elseif ($r.mem_pct -ge 80) { $alerts += [pscustomobject]@{host=$r.hostname; level='中'; item='内存使用率偏高'; value="$($r.mem_pct)%"} }
    foreach ($d in $r.disks) {
        if ($d.pct -ge 90) { $alerts += [pscustomobject]@{host=$r.hostname; level='高'; item="磁盘 $($d.drive) 空间不足"; value="$($d.pct)% (剩 $($d.free) GB)"} }
        elseif ($d.pct -ge 80) { $alerts += [pscustomobject]@{host=$r.hostname; level='中'; item="磁盘 $($d.drive) 使用率偏高"; value="$($d.pct)%"} }
    }
}
[void]$sb.Append("<div class=`"section`" id=`"sec2`"><h2>二、风险汇总</h2></div>`n")
if ($alerts.Count -gt 0) {
    [void]$sb.Append("<table class=`"grid`">`n<thead><tr><th style=`"width:50px`">#</th><th>主机</th><th style=`"width:80px`">等级</th><th>问题</th><th>详情</th></tr></thead><tbody>`n")
    $i = 1
    foreach ($a in ($alerts | Sort-Object @{Expression={ switch($_.level){'高'{1};'中'{2};'低'{3};default{4}} }}, host)) {
        $pillClass = switch ($a.level) { '高' {'pill-solid-red'} '中' {'pill-solid-orange'} '离线' {'pill-solid-gray'} default {'pill-solid-gray'} }
        [void]$sb.Append("<tr><td>$i</td><td><b>$(Esc $a.host)</b></td><td><span class=`"$pillClass`">$(Esc $a.level)</span></td><td>$(Esc $a.item)</td><td>$(Esc $a.value)</td></tr>`n")
        $i++
    }
    [void]$sb.Append("</tbody></table>`n")
} else {
    [void]$sb.Append("<div class=`"card`" style=`"color:#1e7e34`">未发现需要关注的问题，所有主机指标正常。</div>`n")
}

# === 每台详情卡片 ===
[void]$sb.Append("<div class=`"section`" id=`"sec3`"><h2>三、各主机明细</h2></div>`n")
$secIdx = 1
foreach ($r in ($results | Sort-Object target)) {
    $title = if ($r.hostname) { $r.hostname } else { $r.target }
    [void]$sb.Append("<div class=`"host-card`" id=`"host-$secIdx`">`n")
    [void]$sb.Append("<div class=`"host-title`">3.$secIdx $(Esc $title)</div>`n")
    if (-not $r.ok) {
        [void]$sb.Append("<p style=`"color:#d93025`">采集失败: $(Esc $r.error)</p></div>`n")
        $secIdx++; continue
    }

    [void]$sb.Append("<div class=`"host-grid`">`n")

    # ---- 列 1: 基本信息 ----
    [void]$sb.Append("<div class=`"sub-panel`">`n<h4>基本信息</h4>`n")
    [void]$sb.Append("<table class=`"kv`">`n")
    [void]$sb.Append("<tr><td>目标地址</td><td>$(Esc $r.target)</td></tr>`n")
    [void]$sb.Append("<tr><td>计算机名</td><td>$(Esc $r.hostname)</td></tr>`n")
    [void]$sb.Append("<tr><td>操作系统</td><td>$(Esc $r.os)</td></tr>`n")
    [void]$sb.Append("<tr><td>启动时间</td><td>$(Esc $r.boot_time)</td></tr>`n")
    [void]$sb.Append("<tr><td>运行时间</td><td>$(Esc $r.uptime)</td></tr>`n")
    [void]$sb.Append("<tr><td>CPU</td><td>$(Esc $r.cpu_name)<div style=`"color:#6b7280;font-size:11.5px;margin-top:2px`">$($r.cpu_cores) 核 / $($r.cpu_logical) 线程</div></td></tr>`n")
    [void]$sb.Append("</table>`n</div>`n")

    # ---- 列 2: 资源使用 ----
    [void]$sb.Append("<div class=`"sub-panel`">`n<h4>资源使用</h4>`n")
    $cpuColor = if ($r.cpu_load_pct -lt 70) {'#34a853'} elseif ($r.cpu_load_pct -lt 90) {'#f59e0b'} else {'#dc2626'}
    $samplesStr = ($r.cpu_load_samples | ForEach-Object { "$_%" }) -join ' / '
    [void]$sb.Append("<div class=`"res-row`">")
    [void]$sb.Append("<div class=`"res-head`"><span class=`"res-label`">CPU 负载</span><div class=`"res-bar`"><div style=`"width:$($r.cpu_load_pct)%;background:$cpuColor`"></div></div><span class=`"res-pct`" style=`"color:$cpuColor`">$($r.cpu_load_pct)%</span></div>")
    [void]$sb.Append("<div class=`"res-sub`">采样 $samplesStr</div>")
    [void]$sb.Append("</div>`n")
    $memColor = if ($r.mem_pct -lt 70) {'#34a853'} elseif ($r.mem_pct -lt 90) {'#f59e0b'} else {'#dc2626'}
    [void]$sb.Append("<div class=`"res-row`">")
    [void]$sb.Append("<div class=`"res-head`"><span class=`"res-label`">内存使用</span><div class=`"res-bar`"><div style=`"width:$($r.mem_pct)%;background:$memColor`"></div></div><span class=`"res-pct`" style=`"color:$memColor`">$($r.mem_pct)%</span></div>")
    [void]$sb.Append("<div class=`"res-sub`">已用 $($r.mem_used_gb) GB · 可用 $($r.mem_free_gb) GB · 总 $($r.mem_total_gb) GB</div>")
    [void]$sb.Append("</div>`n</div>`n")

    # ---- 列 3: 磁盘使用 ----
    [void]$sb.Append("<div class=`"sub-panel`">`n<h4>磁盘使用 · 按盘符</h4>`n")
    if ($r.disks.Count -gt 0) {
        [void]$sb.Append("<table class=`"disk-table`">`n<tr><th>盘符</th><th>FS</th><th class=`"num-cell`" style=`"text-align:right`">总</th><th class=`"num-cell`" style=`"text-align:right`">已用</th><th class=`"num-cell`" style=`"text-align:right`">可用</th><th>使用率</th></tr>`n")
        foreach ($d in $r.disks) {
            $lbl = if ($d.label) { " <span style=`"color:#9ca3af;font-size:10.5px`">$(Esc $d.label)</span>" } else { '' }
            [void]$sb.Append("<tr><td><span class=`"drv`">$(Esc $d.drive)</span>$lbl</td><td style=`"color:#6b7280;font-size:11px`">$(Esc $d.fs)</td><td class=`"num-cell`" style=`"text-align:right`">$($d.total)G</td><td class=`"num-cell`" style=`"text-align:right`">$($d.used)G</td><td class=`"num-cell`" style=`"text-align:right`">$($d.free)G</td><td>$(PctCell $d.pct)</td></tr>`n")
        }
        [void]$sb.Append("</table>`n")
    } else {
        [void]$sb.Append("<p style=`"color:#6b7280`">无逻辑磁盘信息</p>")
    }
    [void]$sb.Append("</div>`n")

    [void]$sb.Append("</div>`n")  # close host-grid

    # ---- 存储设备 (底部独立分区) ----
    if ($r.physical.Count -gt 0) {
        [void]$sb.Append("<div class=`"storage-section`">`n<h4>存储设备</h4>`n")
        [void]$sb.Append("<table class=`"grid`">`n<thead><tr><th>名称</th><th>类型</th><th>接口</th><th>总容量</th><th>健康</th></tr></thead><tbody>`n")
        foreach ($p in $r.physical) {
            $pillCls = if ($p.health -eq '健康') {'pill pill-green'} else {'pill pill-red'}
            [void]$sb.Append("<tr><td>$(Esc $p.name)</td><td>$(Esc $p.media)</td><td>$(Esc $p.bus)</td><td>$($p.size) GB</td><td><span class=`"$pillCls`">$(Esc $p.health)</span></td></tr>`n")
        }
        [void]$sb.Append("</tbody></table>`n</div>`n")
    }

    [void]$sb.Append("</div>`n")  # close host-card
    $secIdx++
}

[void]$sb.Append(@"
<div class="footer-note">报告生成于 $ts &nbsp;·&nbsp; 由 Multi-Server-Inspection.ps1 自动采集</div>
</body></html>
"@)

# 写 HTML（UTF-8 BOM 让 Word 正确识别中文）
$tsFile = (Get-Date).ToString('yyyyMMdd_HHmmss')
$htmlPath = Join-Path $OutDir "Inspection_$tsFile.html"
$utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
[System.IO.File]::WriteAllText($htmlPath, $sb.ToString(), $utf8Bom)
Write-Host "HTML 报告: $htmlPath" -ForegroundColor Green

# ==================== Word COM 转 .docx ====================
if (-not $NoWord) {
    # 先 probe 本机是否装了 Word，避免在服务器上报丑陋的 COM 异常
    $wordAvailable = $false
    try {
        $probeWord = New-Object -ComObject Word.Application -EA Stop
        $wordAvailable = $true
        $probeWord.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($probeWord) | Out-Null
    } catch {}

    if (-not $wordAvailable) {
        Write-Host ""
        Write-Host "[提示] 本机未安装 Microsoft Word，跳过 .docx 转换。" -ForegroundColor Yellow
        Write-Host "       HTML 报告: $htmlPath" -ForegroundColor Yellow
        Write-Host "       把 HTML 拷到装了 Word 的机器（你的工作站 / DFS01 等），运行:" -ForegroundColor Yellow
        Write-Host "         .\Convert-HtmlToDocx.ps1 -Html '<html 路径>'" -ForegroundColor Yellow
        Write-Host "       或加 -NoWord 抑制本提示。" -ForegroundColor Yellow
    } else {
        $helper = Join-Path (Split-Path -Parent $PSCommandPath) 'Convert-HtmlToDocx.ps1'
        if (-not (Test-Path $helper)) {
            Write-Host "[警告] 找不到 Convert-HtmlToDocx.ps1（应与主脚本同目录），跳过 Word 转换" -ForegroundColor Yellow
        } else {
            Write-Host "`n调用 Convert-HtmlToDocx.ps1 转换为 .docx ..." -ForegroundColor Cyan
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Html $htmlPath
            } catch {
                Write-Host "[警告] Word 转换失败: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "       HTML 已生成，可手动用 Word 打开另存为 .docx" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n完成: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
