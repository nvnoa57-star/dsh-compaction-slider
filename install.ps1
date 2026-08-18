#Requires -Version 5.1
<#
.SYNOPSIS
DSH 上下文压缩阈值滑块插件 - 一键安装/卸载脚本

.DESCRIPTION
自动完成以下全部安装步骤(幂等,可重复执行):
  1. 复制插件包到 $DSH_HOME/profiles/node_modules/@my-scope/
  2. 在 web profile 的 cordis.patch.yml 注册 compaction-settings 插件行
  3. 安装 auto-compact 用户预设(压缩后端为按会话实时读阈值版本)
  4. 设置 agent-presets.default = auto-compact(新会话生效)
每次修改前都会在 $DSH_HOME/install-backups/<时间戳>/ 备份原文件。
本方案不修改任何 node_modules 内部文件,升级 dsh 后无需重装。

.PARAMETER DshHome
DSH 数据目录,默认取 $env:DSH_HOME,否则 ~/.dsh。

.PARAMETER Force
预设已存在时覆盖安装(auto-compact)。

.PARAMETER NoDefault
不修改 agent-presets.default(需要自己在 UI 里选择 auto-compact 预设)。

.PARAMETER Uninstall
反向卸载:移除 patch 行、删除 @my-scope 插件目录。
(preset 与 default 设置属于用户数据,默认保留;加 -Force 一并删除。)

.EXAMPLE
./install.ps1
.EXAMPLE
./install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$Force,
    [switch]$NoDefault,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$Repo = $PSScriptRoot

# ---------- helpers ----------
function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    OK   $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    ...  $msg" -ForegroundColor Gray }

function Get-DshHome {
    if ($DshHome) { return $DshHome }
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    return Join-Path $HOME ".dsh"
}

function Read-Utf8([string]$path) { return [System.IO.File]::ReadAllText($path) }

function Write-Utf8NoBom([string]$path, [string]$content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Backup-File([string]$path) {
    $backupDir = Join-Path (Get-DshHome) ("install-backups\" + [DateTime]::Now.ToString("yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $dest = Join-Path $backupDir ((Split-Path $path -Leaf) + ".bak")
    Copy-Item -LiteralPath $path -Destination $dest
    return $dest
}

# ---------- 1. install plugin packages ----------
function Install-Packages {
    $dshRoot = Get-DshHome
    $destRoot = Join-Path $dshRoot "profiles\node_modules\@my-scope"
    New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
    foreach ($pkg in @("dsh-compaction-ui", "dsh-compaction-live")) {
        $src = Join-Path $Repo $pkg
        if (-not (Test-Path -LiteralPath (Join-Path $src "package.json"))) {
            throw "找不到插件包: $src 。请确认在克隆目录根下运行本脚本。"
        }
        $dest = Join-Path $destRoot $pkg
        Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
        Write-Ok "插件包已安装: @my-scope/$pkg"
    }
}

function Remove-Packages {
    $dshRoot = Get-DshHome
    $destRoot = Join-Path $dshRoot "profiles\node_modules\@my-scope"
    if (Test-Path -LiteralPath $destRoot) {
        Remove-Item -LiteralPath $destRoot -Recurse -Force
        Write-Ok "已删除 @my-scope 插件目录"
    }
}

# ---------- 2. patch web profile cordis.patch.yml ----------
function Update-CordisPatch {
    $dshRoot = Get-DshHome
    $path = Join-Path $dshRoot "profiles\web\cordis.patch.yml"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到 $path 。请先至少运行过一次 dsh web 再安装。"
    }
    $content = Read-Utf8 $path
    if ($content -match "compaction-settings") { Write-Ok "cordis.patch.yml 已包含插件行,跳过"; return }
    $backup = Backup-File $path
    $block = "- insert:`n    - id: compaction-settings`n      name: '@my-scope/dsh-compaction-ui'"
    if ($content -match "(?m)^[ \t]*\[\][ \t]*\r?\n") {
        $content = [regex]::Replace($content, "(?m)^[ \t]*\[\][ \t]*\r?\n", ($block + "`n"), 1)
    } else {
        if (-not $content.EndsWith("`n")) { $content += "`n" }
        $content += $block + "`n"
    }
    Write-Utf8NoBom $path $content
    Write-Ok "cordis.patch.yml 已注册插件行 (备份: $backup)"
}

function Revert-CordisPatch {
    $dshRoot = Get-DshHome
    $path = Join-Path $dshRoot "profiles\web\cordis.patch.yml"
    if (-not (Test-Path -LiteralPath $path)) { return }
    $content = Read-Utf8 $path
    if ($content -notmatch "compaction-settings") { Write-Ok "cordis.patch.yml 无插件行,跳过"; return }
    $backup = Backup-File $path
    $content = [regex]::Replace($content, "(?ms)^- insert:[ \t]*\r?\n[ \t]+- id: compaction-settings[ \t]*\r?\n[ \t]+name: '@my-scope/dsh-compaction-ui'[ \t]*\r?\n?", "", 1)
    if ($content.Trim() -eq "") { $content = "[]`n" }
    Write-Utf8NoBom $path $content
    Write-Ok "cordis.patch.yml 已移除插件行 (备份: $backup)"
}

# ---------- 3. install auto-compact preset ----------
function Install-Preset {
    $dshRoot = Get-DshHome
    $src = Join-Path $Repo "presets\auto-compact"
    if (-not (Test-Path -LiteralPath (Join-Path $src "agent.cordis.yml"))) {
        throw "找不到预设目录: $src"
    }
    $dest = Join-Path $dshRoot ".agent-presets\auto-compact"
    if ((Test-Path -LiteralPath $dest) -and -not $Force) {
        Write-Info "auto-compact 预设已存在,跳过 (-Force 覆盖)"
        return
    }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $dest -Recurse
    Write-Ok "auto-compact 预设已安装"
}

function Remove-Preset {
    $dshRoot = Get-DshHome
    $dest = Join-Path $dshRoot ".agent-presets\auto-compact"
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
        Write-Ok "已删除 auto-compact 预设"
    }
}

# ---------- 4. set default preset ----------
function Set-DefaultPreset {
    $dshRoot = Get-DshHome
    $path = Join-Path $dshRoot "settings.yaml"
    $content = if (Test-Path -LiteralPath $path) { Read-Utf8 $path } else { "" }
    if ($content -match '(?m)^agent-presets:[ \t]*\r?\n[ \t]*default:[ \t]*auto-compact\s*(\r?\n|$)') {
        Write-Ok "settings.yaml 已设置默认预设 auto-compact,跳过"
        return
    }
    if ($content -match '(?m)^agent-presets:[ \t]*\r?$') {
        if ($content -match '(?m)^agent-presets:[ \t]*\r?\n[ \t]*default:[ \t]*') {
            $content = [regex]::Replace($content, "(?m)^(agent-presets:[ \t]*\r?\n[ \t]*default:[ \t]*)[^\r\n]*", '${1}auto-compact', 1)
        } else {
            $content = [regex]::Replace($content, "(?m)^(agent-presets:[ \t]*\r?\n)", ('${1}  default: auto-compact' + "`n"), 1)
        }
    } else {
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`n" }
        $content += "agent-presets:`n  default: auto-compact`n"
    }
    $backup = if (Test-Path -LiteralPath $path) { Backup-File $path } else { "(新建)" }
    Write-Utf8NoBom $path $content
    Write-Ok "settings.yaml 已设置默认预设 auto-compact (备份: $backup)"
}

# ---------- main ----------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  DSH 上下文压缩阈值滑块插件 - 安装脚本" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ("仓库: " + $Repo)
Write-Host ("DSH home: " + (Get-DshHome))

if ($Uninstall) {
    Write-Step "卸载插件"
    Revert-CordisPatch
    Remove-Packages
    if ($Force) { Remove-Preset }
    Write-Step "卸载完成"
    Write-Host "  说明: 若想完全恢复,可手动还原 $((Join-Path (Get-DshHome) 'install-backups')) 中的备份文件。" -ForegroundColor Gray
    exit 0
}

Write-Step "1/4 安装插件包"
Install-Packages

Write-Step "2/4 注册 web profile 插件行"
Update-CordisPatch

Write-Step "3/4 安装 auto-compact 预设"
Install-Preset

Write-Step "4/4 设置默认预设"
if ($NoDefault) { Write-Info "已跳过 (-NoDefault)" } else { Set-DefaultPreset }

Write-Host ""
Write-Host "==================== 安装完成 ====================" -ForegroundColor Green
Write-Host ""
Write-Host " 下一步:" -ForegroundColor White
Write-Host "  1. 重启 dsh web (先停止占用 3080 端口的进程,再重新运行 dsh web)"
Write-Host "  2. 打开浏览器,输入栏 ContextMeter 圆环旁会出现「压缩 XX%」滑块 (0.4~1.0)"
Write-Host "  3. 滑块按会话独立:每个会话可单独调整,默认 80%;也直接在聊天里输入"
Write-Host "     /threshold 0.65 设置;切换会话/重启 dsh 均保留"
Write-Host "  4. 旧会话仍使用之前的预设,需新建会话才生效"
Write-Host "====================================================" -ForegroundColor Green
