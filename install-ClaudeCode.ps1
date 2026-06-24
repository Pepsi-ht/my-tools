<#
.SYNOPSIS
  Claude Code 一键安装脚本 (Windows)
.DESCRIPTION
  自动检测并安装 Claude Code，支持版本锁定与覆盖安装提示。
.PARAMETER Version
  指定安装的版本号（例如 2.1.153）。不指定则安装 2.1.153。
.NOTES
  用法:
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Version 2.1.153
  在线一键安装:
    irm https://raw.githubusercontent.com/Pepsi-ht/my-tools/main/install.ps1 | iex
  指定版本（通过环境变量）:
    $env:CC_VERSION='2.1.153'; irm https://raw.githubusercontent.com/Pepsi-ht/my-tools/main/install.ps1 | iex
#>
param(
    [Parameter(Position=0)]
    [string]$Version = "",
    [string]$InstallPath = ""
)

# ── 执行策略自修复 ──
if ($MyInvocation.MyCommand.Path) {
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
            Write-Host "  [INFO] 检测到执行策略为 $policy，正在以 Bypass 策略重新启动..." -ForegroundColor Blue
            Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Wait -NoNewWindow
            exit $LASTEXITCODE
        }
    } catch {}
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "  [FAIL] 需要 PowerShell 5.0 或更高版本" -ForegroundColor Red
    exit 1
}

if (-not [Environment]::Is64BitProcess) {
    Write-Error "Claude Code 不支持 32 位 Windows，请使用 64 位系统。"
    exit 1
}

# ── 颜色输出 ──
function Write-Info    { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok      { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn    { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err     { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }
function Write-Step    { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

# ── 版本与路径 ──
$script:TargetVersion = if ($Version) { $Version } elseif ($env:CC_VERSION) { $env:CC_VERSION } else { "2.1.153" }
$script:CustomPath = if ($InstallPath) { $InstallPath } elseif ($env:CC_INSTALL_PATH) { $env:CC_INSTALL_PATH } else { "" }
$GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
$DOWNLOAD_DIR = "$env:USERPROFILE\.claude\downloads"
$INSTALL_BASE = "$env:USERPROFILE\.local\share\claude"
$VERSIONS_DIR = "$INSTALL_BASE\versions"
$BIN_DIR = "$env:USERPROFILE\.local\bin"
$LINK_PATH = "$BIN_DIR\claude.exe"
$CONFIG_PATH = "$env:USERPROFILE\.claude.json"

# ── 下载工具 ──
function Get-RemoteText {
    param([string]$Url)
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
            $result = & curl.exe -fsSL --ssl-no-revoke --http1.1 --retry 5 --retry-delay 2 $Url
            if ($LASTEXITCODE -eq 0) {
                if ($result -is [array]) { return ($result -join "`n") }
                return $result
            }
        } catch {}
    }
    return Invoke-RestMethod -Uri $Url -ErrorAction Stop
}

# ── 检测已安装（全面搜索 + Get-Command）──
function Find-ClaudeBinary {
    $searchDirs = @()
    # PATH 目录
    $env:PATH -split ";" | ForEach-Object {
        if ($_ -and (Test-Path $_)) { $searchDirs += $_ }
    }
    # 安装目录
    if (Test-Path $BIN_DIR) { $searchDirs += $BIN_DIR }
    if (Test-Path $VERSIONS_DIR) {
        Get-ChildItem -Path $VERSIONS_DIR -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $searchDirs += $_.FullName
        }
    }
    $searchDirs = $searchDirs | Where-Object { $_ } | Select-Object -Unique
    foreach ($dir in $searchDirs) {
        foreach ($name in @("claude.exe", "claude.cmd")) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate) {
                return @{ Path = $candidate; Dir = $dir }
            }
        }
    }
    # Get-Command 兜底
    try {
        $gcmd = Get-Command claude -ErrorAction SilentlyContinue
        if ($gcmd -and $gcmd.Source) {
            return @{ Path = $gcmd.Source; Dir = Split-Path $gcmd.Source -Parent }
        }
    } catch {}
    return $null
}

# ── 安装核心（npm install）──
function Install-ClaudeCode {
    param([string]$Version)

    Write-Step "正在安装 Claude Code v$Version"

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $pkgSpec = "@anthropic-ai/claude-code@$Version"
        $psi.Arguments = "/c npm install -g $pkgSpec 2>&1"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Err "启动安装进程失败: $_"
        return $false
    }

    Write-Host ""
    Write-Host "  ─── npm 输出 ───" -ForegroundColor Cyan
    Write-Host ""

    $allStdout = ""
    $allStderr = ""
    $promptHandled = $false
    while (-not $proc.HasExited) {
        $line = $proc.StandardOutput.ReadLine()
        if ($line -ne $null) {
            $allStdout += $line + "`n"
            if (-not $promptHandled -and $line -match "Choose which packages to build|space to select") {
                $proc.StandardInput.WriteLine("a")
                $promptHandled = $true
                Write-Host "  [自动选择全部包进行编译] " -ForegroundColor Green
            }
            Write-Host "  $line"
        } else {
            $stderrLine = $proc.StandardError.ReadLine()
            if ($stderrLine -ne $null) {
                $allStderr += $stderrLine + "`n"
                if ($stderrLine -notmatch "^(npm|WARN|http|sill|verbose|timing)") {
                    Write-Host "  $stderrLine" -ForegroundColor Yellow
                }
            } else {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    $remainStdout = $proc.StandardOutput.ReadToEnd()
    $remainStderr = $proc.StandardError.ReadToEnd()
    $allStdout += $remainStdout
    $allStderr += $remainStderr

    Write-Host ""
    $proc.WaitForExit()

    if ($proc.ExitCode -eq 0) {
        Write-Ok "Claude Code $Version 安装成功"
        return $true
    }

    Write-Err "安装失败 (exit code: $($proc.ExitCode))"
    if ($allStderr) {
        Write-Host "  $($allStderr.Trim().Split(\"`n\")[-1])" -ForegroundColor Red
    }
    return $false
}

# ── 主流程 ──
function Main {
    Write-Host ""
    Write-Host "  🤖 Claude Code 一键安装脚本" -ForegroundColor Green
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host ""

    # 刷新 PATH
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machinePath;$userPath"

    # ── 默认路径 ──
    $defaultBase = "$env:USERPROFILE\.local"

    # 检测是否已安装
    $found = Find-ClaudeBinary
    $existingVer = $null
    if ($found) {
        try { $existingVer = (& $found.Path --version 2>$null).Trim() } catch {}
    }
    if (-not $existingVer) {
        try { $existingVer = (& claude --version 2>$null).Trim() } catch {}
    }

    if ($existingVer) {
        Write-Host ""
        Write-Warn "检测到 Claude Code $existingVer 已安装"
        Write-Host "  路径: $($found.Dir)" -ForegroundColor Cyan
        $overwrite = (Read-Host "  是否覆盖安装? [y/N]").Trim()
        if ($overwrite -match "^[Yy]") {
            # 覆盖安装到当前路径
            $installBase = (Split-Path $found.Dir -Parent)
            Write-Info "开始覆盖安装 Claude Code $($script:TargetVersion)..."
            Write-Host ""
        } else {
            Write-Host ""
            $otherPath = (Read-Host "  是否安装到其他路径? [y/N]").Trim()
            if ($otherPath -match "^[Yy]") {
                $inputPath = (Read-Host "  请输入安装路径（留空使用默认: $defaultBase）").Trim()
                $installBase = if ($inputPath) { $inputPath } else { $defaultBase }
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "  🤖 Claude Code 已就位！" -ForegroundColor Green
                Write-Host ""
                return
            }
        }
    } else {
        # 未安装，直接使用默认路径
        $installBase = if ($script:CustomPath) { $script:CustomPath } else { $defaultBase }
    }

    $script:INSTALL_BASE = $installBase
    $script:VERSIONS_DIR = "$installBase\share\claude\versions"
    $script:BIN_DIR = "$installBase\bin"
    $script:LINK_PATH = "$script:BIN_DIR\claude.exe"
    $script:CONFIG_PATH = "$env:USERPROFILE\.claude.json"
    Write-Info "安装目标: $installBase"
    Write-Host ""

    # 执行安装
    $success = Install-ClaudeCode -Version $script:TargetVersion
    if (-not $success) {
        Write-Host "`n按任意键退出..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "  ✅ Claude Code $($script:TargetVersion) 安装完成！" -ForegroundColor Green
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "  位置: $LINK_PATH" -ForegroundColor Cyan
    Write-Host ""
}

Main
