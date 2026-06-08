<#
.SYNOPSIS
    HTML → Word .docx 转换（Word COM，无第三方依赖）
.EXAMPLE
    .\Convert-HtmlToDocx.ps1 -Html '.\Inspection_20260525.html'
    .\Convert-HtmlToDocx.ps1 -Html '.\foo.html' -Out '.\foo.docx'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $Html,
    [string] $Out
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Html)) { throw "找不到 HTML 文件: $Html" }
$Html = (Resolve-Path $Html).Path
if (-not $Out) { $Out = [System.IO.Path]::ChangeExtension($Html, '.docx') }
$Out = [System.IO.Path]::GetFullPath($Out)

# 确保 HTML 有 UTF-8 BOM，否则 Word 把中文当 GBK 解释 → 乱码
$bytes = [System.IO.File]::ReadAllBytes($Html)
if ($bytes.Length -lt 3 -or -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    Write-Host "  补 UTF-8 BOM 到 HTML ..."
    $content = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)
    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($Html, $content, $utf8Bom)
}

Write-Host "启动 Word ..."
$word = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0  # wdAlertsNone

    Write-Host "打开 HTML ..."
    $doc = $word.Documents.Open($Html, $false, $true)  # ConfirmConversions=False, ReadOnly=True

    Write-Host "另存为 $Out ..."
    $wdFormatDocx = 16
    if (Test-Path $Out) { Remove-Item $Out -Force }
    $doc.SaveAs([ref]$Out, [ref]$wdFormatDocx)
    $doc.Close($false)
    Write-Host "完成: $Out" -ForegroundColor Green
} finally {
    if ($word) {
        try { $word.Quit() } catch {}
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
    }
}
