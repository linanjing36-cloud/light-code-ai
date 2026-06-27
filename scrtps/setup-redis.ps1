# setup-redis.ps1 - Install portable Redis for Windows (no Docker)
# Plain Redis is optional (cache / future use).
# Vector memory tools default to VM Redis Stack via scrtps\memory-env.bat (HERMES_MEMORY_BACKEND=redis).
param([switch]$Force)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path $PSScriptRoot -Parent
$RedisDir = Join-Path $RootDir "bin\env\redis"
$RunDir = Join-Path $RootDir "bin\run\redis"

function Install-RedisWindows {
    if ((Test-Path (Join-Path $RedisDir "RedisService.exe")) -and -not $Force) {
        Write-Host "==> Redis already at $RedisDir (use -Force to reinstall)"
        return
    }
    Write-Host "==> Download redis-windows release..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/redis-windows/redis-windows/releases/latest" -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match 'x64.*\.zip$' -or $_.name -match 'win.*\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    }
    if (-not $asset) {
        throw "no zip asset in redis-windows release"
    }
    $zip = Join-Path $env:TEMP "redis-windows.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    if (Test-Path $RedisDir) { Remove-Item $RedisDir -Recurse -Force }
    New-Item -ItemType Directory -Path $RedisDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $RedisDir -Force
    $inner = Get-ChildItem $RedisDir -Recurse -Filter "RedisService.exe" | Select-Object -First 1
    if ($inner -and $inner.DirectoryName -ne $RedisDir) {
        Get-ChildItem $inner.DirectoryName | Move-Item -Destination $RedisDir -Force
        Remove-Item (Split-Path $inner.DirectoryName -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "==> Installed to $RedisDir"
}

New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
Install-RedisWindows

Write-Host ""
Write-Host "Start: scrtps\start-redis.bat"
Write-Host "Note: plain Redis has NO RediSearch vectors."
Write-Host "      memory tools default: HERMES_REDIS_ADDR=192.168.59.129:6379 (VM Redis Stack)."
Write-Host "      local dev fallback: set HERMES_MEMORY_BACKEND=dev"
