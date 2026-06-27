<#
.SYNOPSIS
  一键配置 Headroom（MCP + 项目规则 + 可选代理）

用法:
  .\scrtps\setup-headroom.ps1           # MCP + rtk 规则（推荐，无需改 Cursor 模型设置）
  .\scrtps\setup-headroom.ps1 -Proxy    # 额外启动本地代理 (8787)
#>
param(
    [switch]$Proxy
)

$ErrorActionPreference = "Stop"

$HeadroomExe = "C:\Users\Administrator\.codegeex\mamba\envs\codegeex-agent\Scripts\headroom.exe"
$HeadroomBin = "C:\Users\Administrator\.headroom\bin"
$RootDir     = Split-Path $PSScriptRoot -Parent
$CursorDir   = Join-Path $env:USERPROFILE ".cursor"
$McpJson     = Join-Path $CursorDir "mcp.json"
$SkillDir    = Join-Path $CursorDir "skills\headroom"
$SkillFile   = Join-Path $SkillDir "SKILL.md"

if (-not (Test-Path $HeadroomExe)) {
    throw "未找到 headroom.exe，请先安装: pip install `"headroom-ai[all]`""
}

# 1. MCP 配置（合并已有 codegraph 等，不覆盖）
Write-Host "[headroom] ==> 写入 MCP 配置..."
New-Item -ItemType Directory -Force -Path $CursorDir | Out-Null
$mcp = @{ mcpServers = @{} }
if (Test-Path $McpJson) {
    $mcp = Get-Content $McpJson -Raw | ConvertFrom-Json -AsHashtable
    if (-not $mcp.mcpServers) { $mcp.mcpServers = @{} }
}
$mcp.mcpServers["headroom"] = @{
    type    = "stdio"
    command = $HeadroomExe
    args    = @("mcp", "serve")
}
($mcp | ConvertTo-Json -Depth 10) | Set-Content -Path $McpJson -Encoding UTF8

# 2. Agent Skill
Write-Host "[headroom] ==> 安装 Agent Skill..."
New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null
@'
---
name: headroom
description: >-
  Use Headroom to compress large tool outputs, logs, files, and search results
  before reasoning over them. Invoke when context is token-heavy or headroom MCP
  tools are available.
---

# Headroom

压缩大段工具输出后再分析。MCP: `headroom_compress` / `headroom_retrieve` / `headroom_stats`.
'@ | Set-Content -Path $SkillFile -Encoding UTF8

# 3. 项目 rtk 规则（wrap cursor --no-proxy 等价，仅注入规则不阻塞）
Write-Host "[headroom] ==> 注入项目 .cursorrules (rtk)..."
$env:PATH = "$(Split-Path $HeadroomExe -Parent);$HeadroomBin;" + $env:PATH
Push-Location $RootDir
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $HeadroomExe wrap cursor --no-proxy 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
}
finally { Pop-Location }

# 4. 可选：后台代理
if ($Proxy) {
    Write-Host "[headroom] ==> 启动代理 http://127.0.0.1:8787 ..."
    $running = Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue
    if (-not $running) {
        Start-Process -FilePath $HeadroomExe -ArgumentList "proxy","--port","8787" -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    Write-Host "    OpenAI Base URL: http://127.0.0.1:8787/p/light-code-ai-1/v1"
    Write-Host "    Anthropic Base URL: http://127.0.0.1:8787/p/light-code-ai-1"
    Write-Host "    Cursor: Settings > Models > Override Base URL"
}

Write-Host "[headroom] ==> 完成."
Write-Host "    MCP:     $McpJson"
Write-Host "    Skill:   $SkillFile"
Write-Host "    规则:    $RootDir\.cursorrules"
Write-Host "[headroom] ==> 请重启 Cursor 使 MCP 生效。"
Write-Host "[headroom] ==> 自测: 在 Agent 中说「调用 headroom_stats」"
