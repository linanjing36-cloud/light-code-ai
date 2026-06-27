# setup-docker.ps1 - Install Docker Desktop + China registry mirrors (Windows)
param([switch]$SkipInstall)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-WslPrerequisites {
    Write-Host "==> Enable WSL / VirtualMachinePlatform for Docker Desktop..."
    $features = @(
        "Microsoft-Windows-Subsystem-Linux",
        "VirtualMachinePlatform"
    )
    foreach ($f in $features) {
        $st = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($st -and $st.State -eq "Enabled") {
            Write-Host "    already enabled: $f"
            continue
        }
        Write-Host "    enabling: $f ..."
        Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -All | Out-Null
    }
    try {
        wsl --install --no-distribution 2>&1 | Out-Null
    } catch {
        Write-Warning "wsl --install needs reboot or manual run: $_"
    }
    Write-Host "    WSL configured (reboot may be required)"
}

function Install-DockerDesktop {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Host "==> docker already in PATH, skip winget"
        return
    }
    Write-Host "==> winget install Docker.DockerDesktop ..."
    winget install Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity
}

function Get-RegistryMirrors {
    $mirrors = @()
    if ($env:HERMES_ALIYUN_MIRROR) {
        $mirrors += $env:HERMES_ALIYUN_MIRROR.TrimEnd('/')
    }
    # Aliyun / Tencent / USTC(academic) / NetEase Hub mirrors
    $mirrors += @(
        "https://registry.cn-hangzhou.aliyuncs.com",
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://hub-mirror.c.163.com"
    )
    $seen = @{}
    $out = @()
    foreach ($m in $mirrors) {
        if (-not $seen.ContainsKey($m)) {
            $seen[$m] = $true
            $out += $m
        }
    }
    return $out
}

function Write-DockerDaemonJson {
    $dockerDir = Join-Path $env:USERPROFILE ".docker"
    if (-not (Test-Path $dockerDir)) {
        New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    }
    $daemonPath = Join-Path $dockerDir "daemon.json"
    $mirrors = Get-RegistryMirrors
    $obj = [ordered]@{
        "registry-mirrors" = $mirrors
    }
    $json = ($obj | ConvertTo-Json -Depth 5)
    [System.IO.File]::WriteAllText($daemonPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "==> wrote $daemonPath"
    Write-Host $json
}

if (-not (Test-Admin)) {
    Write-Warning "Run as Administrator to enable WSL. Continuing with daemon.json / winget only."
}

if (-not $SkipInstall) {
    if (Test-Admin) {
        Enable-WslPrerequisites
    } else {
        Write-Warning "Not admin: skip WSL enable. Run: wsl --install"
    }
    Install-DockerDesktop
}

Write-DockerDaemonJson

Write-Host ""
Write-Host "========================================"
Write-Host " Docker Desktop installed."
Write-Host " Mirror config: $env:USERPROFILE\.docker\daemon.json"
Write-Host ""
Write-Host " IMPORTANT: Reboot Windows now if WSL was just enabled."
Write-Host " After reboot:"
Write-Host "   1. Start Docker Desktop (wait until engine is running)"
Write-Host "   2. docker info"
Write-Host "   3. scrtps\start-redis.bat"
Write-Host ""
Write-Host " Mirrors configured (in order):"
Write-Host "   - Aliyun:   https://registry.cn-hangzhou.aliyuncs.com"
Write-Host "   - Tencent:  https://mirror.ccs.tencentyun.com"
Write-Host "   - USTC:     https://docker.mirrors.ustc.edu.cn  (Tsinghua TUNA has no Hub mirror)"
Write-Host "   - NetEase:  https://hub-mirror.c.163.com"
Write-Host ""
Write-Host " Aliyun personal accelerator (best):"
Write-Host "   https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors"
Write-Host "   then: `$env:HERMES_ALIYUN_MIRROR='https://xxxx.mirror.aliyuncs.com'"
Write-Host "   then: .\scrtps\setup-docker.ps1 -SkipInstall"
Write-Host "========================================"
