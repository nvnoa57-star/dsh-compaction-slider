#Requires -Version 5.1
<#
.SYNOPSIS
DSH 上下文压缩阈值滑块插件 - 一键安装/卸载脚本

.DESCRIPTION
自动完成以下全部安装步骤(幂等,可重复执行):
  1. 复制插件包到 $DSH_HOME/profiles/node_modules/@my-scope/
  2. 在 web profile 的 cordis.patch.yml 注册 compaction-settings 插件行
  3. 在 dsh-host-apiproxy 的 WEB_SETTINGS_NAMESPACES 放行 "compaction"
  4. 安装 auto-compact 用户预设(压缩后端为实时读阈值版本)
  5. 设置 agent-presets.default = auto-compact(新会话生效)
每次修改前都会在 $DSH_HOME/install-backups/<时间戳>/ 备份原文件。

.PARAMETER DshHome
DSH 数据目录,默认取 $env:DSH_HOME,否则 ~/.dsh。

.PARAMETER ApiProxyFile
dsh-host-apiproxy 的 index.js 路径。默认自动探测
($DSH_HOME/profiles/node_modules/@deepseek-ai/dsh-host-apiproxy 或 npm 全局目录)。

.PARAMETER Force
预设已存在时覆盖安装(auto-compact)。

.PARAMETER NoDefault
不修改 agent-presets.default(需要自己在 UI 里选择 auto-compact 预设)。

.PARAMETER SkipApiProxy
跳过 apiproxy 放行名单修改(仅当你的 dsh 版本已原生放行 compaction 时使用)。

.PARAMETER Uninstall
反向卸载:移除 apiproxy 放行、移除 patch 行、删除 @my-scope 插件目录。
(preset 与 default 设置属于用户数据,默认保留;加 -Force 一并删除。)

.EXAMPLE
./install.ps1
.EXAMPLE
./install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [string]$ApiProxyFile,
    [switch]$Force,
    [switch]$NoDefault,
    [switch]$SkipApiProxy,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$Repo = $PSScriptRoot

# ---------- helpers ----------
function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    OK   $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    ...  $msg" -ForegroundColor Gray }
function Write-WarnMsg([string]$msg) { Write-Host "    !!   $msg" -ForegroundColor Yellow }

function Get-DshHome {
    if ($DshHome) { return $DshHome }
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    return Join-Path $HOME ".dsh"
}

function Get-NpmGlobalRoot {
    $npm = if ($env:OS -eq "Windows_NT") { "npm.cmd" } else { "npm" }
    try {
        $root = (& $npm root -g 2>$null | Select-Object -Last 1)
        if ($root -and (Test-Path -LiteralPath $root)) { return $root.Trim() }
    } catch { }
    if ($env:APPDATA) { $alt = Join-Path $env:APPDATA "npm\node_modules"; if (Test-Path -LiteralPath $alt) { return $alt } }
    return $null
}

function Resolve-ApiProxy {
    if ($ApiProxyFile) { return $ApiProxyFile }
    $dshRoot = Get-DshHome
    $candidates = @(
        (Join-Path $dshRoot "profiles\node_modules\@deepseek-ai\dsh-host-apiproxy\lib\index.js"),
        (Join-Path $dshRoot "profiles\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-host-apiproxy\lib\index.js")
    )
    $npmRoot = Get-NpmGlobalRoot
    if ($npmRoot) {
        $candidates += (Join-Path $npmRoot "@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-host-apiproxy\lib\index.js")
        $candidates += (Join-Path $npmRoot "@deepseek-ai\dsh-host-apiproxy\lib\index.js")
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
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

# ---------- 3. patch apiproxy allowlist ----------
function Update-ApiProxy {
    $path = Resolve-ApiProxy
    if (-not $path) {
        Write-WarnMsg "找不到 dsh-host-apiproxy/index.js,请手动在 WEB_SETTINGS_NAMESPACES 数组中添加 `"compaction`""
        return
    }
    $content = Read-Utf8 $path
    if ($content -match '(?s)WEB_SETTINGS_NAMESPACES\s*=\s*\[[^\]]*"compaction"') {
        Write-Ok "apiproxy 已放行 compaction,跳过 ($path)"
        return
    }
    if ($content -notmatch 'WEB_SETTINGS_NAMESPACES\s*=\s*\[') {
        Write-WarnMsg "在 $path 中未找到 WEB_SETTINGS_NAMESPACES,dsh 版本可能不兼容,请手动放行 compaction"
        return
    }
    $backup = Backup-File $path
    $content = [regex]::Replace($content, "(WEB_SETTINGS_NAMESPACES\s*=\s*\[)", ('${1}' + "`n`t`"compaction`","), 1)
    Write-Utf8NoBom $path $content
    Write-Ok "apiproxy 已放行 compaction (备份: $backup)"
}

function Revert-ApiProxy {
    $path = Resolve-ApiProxy
    if (-not $path) { return }
    $content = Read-Utf8 $path
    if ($content -notmatch '(?m)^[ \t]*"compaction",[ \t]*$') { Write-Ok "apiproxy 无 compaction 放行,跳过"; return }
    $backup = Backup-File $path
    $content = [regex]::Replace($content, "(?m)^[ \t]*`"compaction`",[ \t]*\r?\n", "", 1)
    Write-Utf8NoBom $path $content
    Write-Ok "apiproxy 已移除 compaction 放行 (备份: $backup)"
}

# ---------- 4. install auto-compact preset ----------
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

# ---------- 5. set default preset ----------
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
    if (-not $SkipApiProxy) { Revert-ApiProxy }
    Revert-CordisPatch
    Remove-Packages
    if ($Force) { Remove-Preset }
    Write-Step "卸载完成"
    Write-Host "  说明: 若想完全恢复,可手动还原 $((Join-Path (Get-DshHome) 'install-backups')) 中的备份文件。" -ForegroundColor Gray
    exit 0
}

Write-Step "1/5 安装插件包"
Install-Packages

Write-Step "2/5 注册 web profile 插件行"
Update-CordisPatch

Write-Step "3/5 放行 compaction settings 命名空间"
if ($SkipApiProxy) { Write-Info "已跳过 (-SkipApiProxy)" } else { Update-ApiProxy }

Write-Step "4/5 安装 auto-compact 预设"
Install-Preset

Write-Step "5/5 设置默认预设"
if ($NoDefault) { Write-Info "已跳过 (-NoDefault)" } else { Set-DefaultPreset }

Write-Host ""
Write-Host "==================== 安装完成 ====================" -ForegroundColor Green
Write-Host ""
Write-Host " 下一步:" -ForegroundColor White
Write-Host "  1. 重启 dsh web (先停止占用 3080 端口的进程,再重新运行 dsh web)"
Write-Host "  2. 打开浏览器,输入栏 ContextMeter 圆环旁会出现「压缩 XX%」滑块 (0.4~1.0)"
Write-Host "  3. 注意: 旧会话仍使用之前的预设,需新建会话才生效;滑块调整对运行中会话"
Write-Host "     在下一个 step 边界即时生效"
Write-Host ""
Write-Host "  已知限制: dsh 升级 (npm update) 会覆盖 apiproxy 放行,重跑本脚本即可修复。" -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Green
