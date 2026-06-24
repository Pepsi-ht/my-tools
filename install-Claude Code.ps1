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
    [string]$Version = ""
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

# ── 安装核心（从 GCS 下载 + 校验）──
function Install-ClaudeCode {
    param([string]$Version)

    Write-Step "正在安装 Claude Code v$Version"

    # 平台
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $platform = "win32-arm64" } else { $platform = "win32-x64" }

    New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

    # 获取 manifest 校验
    try {
        $manifestText = Get-RemoteText -Url "$GCS_BUCKET/$Version/manifest.json"
        $manifest = $manifestText | ConvertFrom-Json
        $checksum = $manifest.platforms.$platform.checksum
        $expectedSize = $manifest.platforms.$platform.size
        if (-not $checksum) { throw "平台 $platform 在 manifest 中不存在" }
    } catch {
        Write-Err "获取版本信息失败: $_"
        return $false
    }

    # 下载
    $binaryPath = "$DOWNLOAD_DIR\claude-$Version-$platform.exe"
    $downloadUrl = "$GCS_BUCKET/$Version/$platform/claude.exe"

    Write-Info "版本: $Version | 平台: $platform"
    Write-Info "正在下载 Claude Code..."

    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL --ssl-no-revoke --http1.1 --retry 5 --retry-delay 2 -o $binaryPath $downloadUrl
            if ($LASTEXITCODE -ne 0) { throw "curl.exe 失败，退出码 $LASTEXITCODE" }
        } else {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $binaryPath -ErrorAction Stop
        }
        if ($expectedSize) {
            $actualSize = (Get-Item $binaryPath).Length
            if ($actualSize -ne [int64]$expectedSize) { throw "文件大小不匹配，期望 $expectedSize，实际 $actualSize" }
        }
    } catch {
        Write-Err "下载失败: $_"
        if (Test-Path $binaryPath) { Remove-Item -Force $binaryPath }
        return $false
    }

    # SHA256 校验
    $actualChecksum = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
    if ($actualChecksum -ne $checksum) {
        Write-Err "校验和不匹配，文件可能已损坏"
        Remove-Item -Force $binaryPath
        return $false
    }

    Write-Ok "下载完成，SHA256 校验通过"

    # 安装
    Write-Info "正在安装..."
    try {
        New-Item -ItemType Directory -Force -Path $VERSIONS_DIR | Out-Null
        New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null

        $finalPath = "$VERSIONS_DIR\$Version.exe"
        if (Test-Path $finalPath) { Remove-Item -Force $finalPath }
        Move-Item -Force $binaryPath $finalPath
        Copy-Item -Force $finalPath $LINK_PATH

        # 配置
        $data = @{ installMethod = "native"; autoUpdates = $false; autoUpdatesProtectedForNative = $true }
        if (Test-Path $CONFIG_PATH) {
            try {
                $existing = Get-Content -Raw -Path $CONFIG_PATH | ConvertFrom-Json -AsHashtable
                if ($existing) {
                    $data["firstStartTime"] = $existing["firstStartTime"]
                    Copy-Item -Force $CONFIG_PATH "$env:USERPROFILE\.claude\backups\.claude.json.backup.$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        if (-not $data.ContainsKey("firstStartTime")) {
            $data["firstStartTime"] = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $data | ConvertTo-Json -Depth 10 | Set-Content -Path $CONFIG_PATH -Encoding UTF8

        # 添加到 PATH
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($currentPath -notlike "*$BIN_DIR*") {
            [Environment]::SetEnvironmentVariable("PATH", "$BIN_DIR;$currentPath", "User")
            $env:PATH = "$BIN_DIR;$env:PATH"
            Write-Info "已将 $BIN_DIR 添加到用户 PATH"
        }

        return $true
    } catch {
        Write-Err "安装失败: $_"
        return $false
    }
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
        if ($overwrite -notmatch "^[Yy]") {
            Write-Host ""
            Write-Host "  🤖 Claude Code 已就位！" -ForegroundColor Green
            Write-Host ""
            return
        }
        Write-Info "开始覆盖安装 Claude Code $($script:TargetVersion)..."
        Write-Host ""
    }

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
