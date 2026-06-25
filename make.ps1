<#
.SYNOPSIS
make.ps1 - Hermes Agent 大脑构建与运行 (Windows / PowerShell 版, Makefile 的等价物)

目标:
  .\make.ps1 bin      准备 bin\ 目录骨架 (创建子目录 + 拷贝 .bat 脚本, 不编译产物)
  .\make.ps1 env      检查并安装本地 SDK (Erlang 29 / Go 1.26 / Node.js / rebar3 / wails3) 到 bin\env\
  .\make.ps1 agent    编译 Agent-brains (Erlang/OTP), 产物安装到 bin\erl_bin\
  .\make.ps1 run      启动 Agent 大脑 (前台, 优化参数, Ctrl+C 退出)
  .\make.ps1 stop     优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)
  .\make.ps1 clean    清理编译产物与 bin\erl_bin\
  .\make.ps1 test      跑 eunit 测试
  .\make.ps1 help      显示帮助

模式切换 (run 时):
  .\make.ps1 run                       # 默认开发模式 (MODE=dev)
  $env:MODE='prod'; .\make.ps1 run     # 发布模式
#>

param(
    [Parameter(Position = 0)]
    [string]$Target = ""
)

$ErrorActionPreference = "Stop"

# === 路径定义 (与 Makefile 对齐) ===
$RootDir   = $PSScriptRoot
$AgentDir  = Join-Path $RootDir "Agent-brains"
$BinDir    = Join-Path $RootDir "bin"
$ErlBin    = Join-Path $RootDir "bin\erl_bin"
$EionBin   = Join-Path $RootDir "bin\eion_bin"
$WailsBin  = Join-Path $RootDir "bin\wails_v3_bin"
$ScrtpsDir = Join-Path $RootDir "scrtps"
$EnvDir    = Join-Path $RootDir "bin\env"

# === env 目标: 本地 SDK 版本目标 (按需 bump) ===
$SdkErlangVer = "29.0.2"
$SdkGoVer     = "1.26.4"
$SdkNodeVer   = "22.22.2"   # Jod LTS
$SdkNodeMin   = "20.0.0"   # 系统已有 Node 的最低可接受版本
$SdkWailsPkg  = "github.com/wailsapp/wails/v3/cmd/wails3@latest"

# --- env 辅助函数 ---
function Test-CommandExists($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# 把 "29" / "1.26" / "1.26.4" 归一为 [Version] (不足 3 段补 0)
function ConvertTo-VersionObj($v) {
    if (-not $v) { return $null }
    # @(...) 强制数组上下文, 避免单段版本 (如 "29") 返回标量导致后续 $parts += 0 变成算术加法 (死循环)
    $parts = @(($v.TrimStart('v', 'V') -split '[\. ]') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    if ($parts.Count -lt 1) { return $null }
    while ($parts.Count -lt 3) { $parts += 0 }
    return [Version]("$($parts[0]).$($parts[1]).$($parts[2])")
}
function Test-VersionGe($a, $b) {
    $va = ConvertTo-VersionObj $a
    $vb = ConvertTo-VersionObj $b
    if (-not $va -or -not $vb) { return $false }
    return $va -ge $vb
}

# 读取已装 Erlang/OTP 主版本 (启动 VM 取 otp_release)
function Get-ErlangOtpVersion {
    if (-not (Test-CommandExists "erl")) { return $null }
    try {
        # 用 [126,115] 表示 "~s", 避免 -eval 里出现双引号被 shell 重新解析
        $out = & erl -noshell -eval 'io:format([126,115],[erlang:system_info(otp_release)]), halt().' 2>$null
        return ($out -join '').Trim()
    } catch { return $null }
}
function Get-GoVersion {
    if (-not (Test-CommandExists "go")) { return $null }
    try {
        $line = (go version 2>$null) -join ' '
        if ($line -match 'go(\d+\.\d+(?:\.\d+)?)') { return $Matches[1] }
    } catch {}
    return $null
}
function Get-NodeVersion {
    if (-not (Test-CommandExists "node")) { return $null }
    try {
        $line = (node --version 2>$null) -join ' '
        if ($line -match 'v?(\d+\.\d+(?:\.\d+)?)') { return $Matches[1] }
    } catch {}
    return $null
}

# 下载文件 (支持多源 fallback, 用于国内/国外镜像切换)
function Invoke-DownloadFile($urls, $dest) {
    if ($urls -is [string]) { $urls = @($urls) }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    foreach ($u in $urls) {
        try {
            Write-Host "      GET $u"
            $client = New-Object System.Net.WebClient
            $client.Headers.Add('User-Agent', 'make.ps1')
            $client.DownloadFile($u, $dest)
            return
        } catch {
            Write-Host "      [失败] $($_.Exception.Message)"
        }
    }
    throw "所有下载源均失败: $($urls -join ' ; ')"
}

function Install-Erlang {
    Write-Host "    下载 Erlang/OTP $SdkErlangVer ..."
    $exe = Join-Path $EnvDir "otp_win64_$SdkErlangVer.exe"
    $urls = @(
        "https://erlang.org/download/otp_win64_$SdkErlangVer.exe",
        "https://github.com/erlang/otp/releases/download/OTP-$SdkErlangVer/otp_win64_$SdkErlangVer.exe"
    )
    Invoke-DownloadFile $urls $exe
    $installDir = Join-Path $EnvDir "erlang"
    if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
    Write-Host "    静默安装到 $installDir ..."
    # NSIS: /S 静默, /D=目录 (必须最后, 路径无空格无尾反斜杠)
    Start-Process -FilePath $exe -ArgumentList "/S", "/D=$installDir" -Wait | Out-Null
    # 优先用顶层 bin\ (含 erl/escript/epmd/erlc 包装器), 找不到再递归搜
    $erlBin = Join-Path $installDir "bin"
    if (-not (Test-Path (Join-Path $erlBin "erl.exe"))) {
        $erlExe = Get-ChildItem -Path $installDir -Recurse -Filter "erl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $erlExe) { throw "Erlang 安装后未找到 erl.exe" }
        $erlBin = $erlExe.DirectoryName
    }
    return $erlBin
}

function Install-Go {
    Write-Host "    下载 Go $SdkGoVer ..."
    $zip = Join-Path $EnvDir "go$SdkGoVer.windows-amd64.zip"
    $urls = @(
        "https://golang.google.cn/dl/go$SdkGoVer.windows-amd64.zip",
        "https://go.dev/dl/go$SdkGoVer.windows-amd64.zip"
    )
    Invoke-DownloadFile $urls $zip
    $goRoot = Join-Path $EnvDir "go"
    if (Test-Path $goRoot) { Remove-Item -Recurse -Force $goRoot }
    Write-Host "    解压到 $EnvDir ..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $EnvDir)   # 产生 bin\env\go\
    Remove-Item $zip -Force
    return (Join-Path $goRoot "bin")    # go.exe
}

function Install-Node {
    Write-Host "    下载 Node.js $SdkNodeVer ..."
    $zip = Join-Path $EnvDir "node-v$SdkNodeVer-win-x64.zip"
    $urls = @(
        "https://npmmirror.com/mirrors/node/v$SdkNodeVer/node-v$SdkNodeVer-win-x64.zip",
        "https://nodejs.org/dist/v$SdkNodeVer/node-v$SdkNodeVer-win-x64.zip"
    )
    Invoke-DownloadFile $urls $zip
    $extracted = Join-Path $EnvDir "node-v$SdkNodeVer-win-x64"
    if (Test-Path $extracted) { Remove-Item -Recurse -Force $extracted }
    Write-Host "    解压 ..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $EnvDir)
    $target = Join-Path $EnvDir "nodejs"
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $extracted $target
    Remove-Item $zip -Force
    return $target   # node.exe / npm.cmd
}

function Install-Rebar3 {
    Write-Host "    下载 rebar3 escript ..."
    $dest = Join-Path $EnvDir "rebar3"
    Invoke-DownloadFile @("https://s3.amazonaws.com/rebar3/rebar3") $dest
    # 生成 rebar3.cmd 包装器 (escript 调用 rebar3 escript)
    $cmd = Join-Path $EnvDir "rebar3.cmd"
    $cmdLines = @('@echo off', 'escript.exe "%~dp0rebar3" %*')
    Set-Content -Path $cmd -Value $cmdLines -Encoding ASCII
    return $EnvDir
}

function Install-Wails3 {
    Write-Host "    go install wails3 ..."
    $gopath = Join-Path $EnvDir "gopath"
    New-Item -ItemType Directory -Force -Path (Join-Path $gopath "bin") | Out-Null
    $env:GOPATH = $gopath
    $env:GOPROXY = "https://goproxy.cn,direct"
    & go install $SdkWailsPkg
    if ($LASTEXITCODE -ne 0) { throw "go install wails3 失败 (exit $LASTEXITCODE)" }
    return (Join-Path $gopath "bin")   # wails3.exe
}

# 生成 activate.ps1 / activate.bat (把 bin\env 下工具前置到 PATH)
function Write-ActivateScripts($envPaths, $goRoot, $goPath) {
    if (-not $envPaths -or $envPaths.Count -eq 0) { return }
    $pathsJoined = $envPaths -join ';'
    # activate.ps1 (给 PowerShell 会话)
    $psLines = @()
    $psLines += '# 由 make.ps1 env 自动生成 — 在当前 PowerShell 会话激活本地 env'
    $psLines += '$env:PATH = "' + $pathsJoined + ';" + $env:PATH'
    if ($goRoot) { $psLines += '$env:GOROOT = "' + $goRoot + '"' }
    if ($goPath) { $psLines += '$env:GOPATH = "' + $goPath + '"' }
    $psLines += '$env:GOPROXY = "https://goproxy.cn,direct"'
    Set-Content -Path (Join-Path $EnvDir "activate.ps1") -Value $psLines -Encoding UTF8
    # activate.bat (给 cmd / .bat 脚本)
    $batLines = @()
    $batLines += '@echo off'
    $batLines += 'set "PATH=' + $pathsJoined + ';%PATH%"'
    if ($goRoot) { $batLines += 'set "GOROOT=' + $goRoot + '"' }
    if ($goPath) { $batLines += 'set "GOPATH=' + $goPath + '"' }
    $batLines += 'set "GOPROXY=https://goproxy.cn,direct"'
    Set-Content -Path (Join-Path $EnvDir "activate.bat") -Value $batLines -Encoding ASCII
}

# env 目标: 检测 + 缺失则本地安装到 bin\env
function Invoke-Env {
    Write-Host "[make] ==> 检查本地开发环境..."
    New-Item -ItemType Directory -Force -Path $EnvDir | Out-Null

    $envPaths = @()
    $goRoot = $null
    $goPath = $null

    # --- Erlang/OTP 29 ---
    $erlVer = Get-ErlangOtpVersion
    if (Test-VersionGe $erlVer "29.0.0") {
        Write-Host "  [OK]      Erlang/OTP $erlVer (>= 29)"
    } else {
        $found = if ($erlVer) { $erlVer } else { "无" }
        Write-Host "  [缺失/低]  Erlang (found: $found) -> 安装 OTP $SdkErlangVer 到 bin\env"
        $envPaths += (Install-Erlang)
    }

    # --- Go 1.26 ---
    $gVer = Get-GoVersion
    if (Test-VersionGe $gVer "1.26.0") {
        Write-Host "  [OK]      Go $gVer (>= 1.26)"
    } else {
        $found = if ($gVer) { $gVer } else { "无" }
        Write-Host "  [缺失/低]  Go (found: $found) -> 安装 Go $SdkGoVer 到 bin\env"
        $envPaths += (Install-Go)
        $goRoot = Join-Path $EnvDir "go"
    }

    # --- Node.js ---
    $nVer = Get-NodeVersion
    if (Test-VersionGe $nVer $SdkNodeMin) {
        Write-Host "  [OK]      Node.js $nVer (>= $SdkNodeMin)"
    } else {
        $found = if ($nVer) { $nVer } else { "无" }
        Write-Host "  [缺失/低]  Node.js (found: $found) -> 安装 Node $SdkNodeVer 到 bin\env"
        $envPaths += (Install-Node)
    }

    # --- rebar3 ---
    if (Test-CommandExists "rebar3") {
        Write-Host "  [OK]      rebar3 已在 PATH"
    } else {
        Write-Host "  [缺失]    rebar3 -> 下载到 bin\env\rebar3"
        Install-Rebar3 | Out-Null
        $envPaths += $EnvDir
    }

    # --- wails3 ---
    if (Test-CommandExists "wails3") {
        Write-Host "  [OK]      wails3 已在 PATH"
    } else {
        Write-Host "  [缺失]    wails3 -> go install"
        # wails3 依赖 go; 若 go 刚装到 env 还未在 PATH, 临时注入以便 go install
        $savedPath = $env:PATH
        if ($goRoot) { $env:PATH = (Join-Path $goRoot "bin") + ";" + $env:PATH }
        if (-not (Test-CommandExists "go")) {
            Write-Host "  [跳过]    wails3 依赖 Go, Go 仍不可用, 请重试 .\make.ps1 env"
            $env:PATH = $savedPath
        } else {
            try {
                $envPaths += (Install-Wails3)
                $goPath = Join-Path $EnvDir "gopath"
            } catch {
                Write-Host "  [警告]    wails3 安装失败: $($_.Exception.Message)"
            }
            $env:PATH = $savedPath
        }
    }

    # --- 生成 activate 脚本 ---
    Write-ActivateScripts $envPaths $goRoot $goPath

    Write-Host "[make] ==> 完成. env 目录:"
    if (Test-Path $EnvDir) {
        Get-ChildItem -Path $EnvDir -Force |
            Where-Object { $_.Name -ne 'activate.ps1' -and $_.Name -ne 'activate.bat' } |
            ForEach-Object { Write-Host "    $($_.Name)" }
    }
    Write-Host "[make] ==> 已生成激活脚本 (后续 make target 会自动加载 activate.ps1):"
    Write-Host "    PowerShell:  . .\bin\env\activate.ps1"
    Write-Host "    cmd:         call bin\env\activate.bat"
    Write-Host "[make] ==> 单独跑 wails 构建: 先 . .\bin\env\activate.ps1, 再 cd Wails-v3; wails3 build"
}

# 准备 bin\ 目录骨架 (创建子目录 + 拷贝 scrtps\ 下 .bat 脚本到 bin\)
# 不编译任何产物, 只搭骨架. 编译产物用:
#   .\make.ps1 agent              -> bin\erl_bin\        (Erlang/OTP)
#   cd Wails-v3; wails3 build     -> bin\wails_v3_bin\  (Wails v3)
function Invoke-Bin {
    Write-Host "[make] ==> 准备 bin\ 目录结构..."
    New-Item -ItemType Directory -Force -Path $BinDir   | Out-Null
    New-Item -ItemType Directory -Force -Path $ErlBin  | Out-Null
    New-Item -ItemType Directory -Force -Path $EionBin | Out-Null
    New-Item -ItemType Directory -Force -Path $WailsBin | Out-Null

    # 拷贝 scrtps\ 下 .bat 脚本到 bin\ (start.bat / stop.bat / start-wails.bat / stop-wails.bat)
    $batFiles = Get-ChildItem -Path $ScrtpsDir -Filter "*.bat" -ErrorAction SilentlyContinue
    if ($batFiles) {
        foreach ($f in $batFiles) {
            Copy-Item -Path $f.FullName -Destination $BinDir -Force
        }
    }

    Write-Host "[make] ==> 目录结构 (bin\ 下):"
    Get-ChildItem -Path $BinDir -Directory | ForEach-Object { Write-Host "    $($_.Name)" }

    Write-Host "[make] ==> 脚本 (.bat):"
    $scripts = Get-ChildItem -Path $BinDir -Filter "*.bat" -ErrorAction SilentlyContinue
    if ($scripts) {
        $scripts | ForEach-Object { Write-Host "    $($_.Name)" }
    } else {
        Write-Host "    (无)"
    }

    Write-Host "[make] ==> 完成. 编译产物:"
    Write-Host "    .\make.ps1 agent              # Erlang -> bin\erl_bin\"
    Write-Host "    cd Wails-v3; wails3 build     # Wails  -> bin\wails_v3_bin\"
    Write-Host "[make] ==> 启动 (二选一, 不可同时运行):"
    Write-Host "    .\make.ps1 run                # 纯命令行模式 (Erlang, 无 GUI)"
    Write-Host "    .\bin\start-wails.bat         # 桌面面板模式 (Wails 自动拉起 Erlang)"
}

# 编译 Agent 大脑 (Erlang/OTP), 产物安装到 bin\erl_bin\
# 拷贝 _build\default\lib\ (含 hermes_brains + deps) + config\sys.config (给 prod 模式)
function Invoke-Agent {
    Write-Host "[make] ==> 编译 Agent-brains..."
    Push-Location $AgentDir
    try {
        & rebar3 compile
        if ($LASTEXITCODE -ne 0) { throw "rebar3 compile 失败 (exit $LASTEXITCODE)" }
    }
    finally { Pop-Location }

    Write-Host "[make] ==> 安装 beams 到 $ErlBin ..."
    if (Test-Path $ErlBin) { Remove-Item -Recurse -Force $ErlBin }
    $configDir = Join-Path $ErlBin "config"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    # 拷贝 _build\default\lib\ 下所有 OTP app (含 hermes_brains + deps) 到 erl_bin\
    $libDir = Join-Path $AgentDir "_build\default\lib"
    Copy-Item -Path "$libDir\*" -Destination $ErlBin -Recurse -Force
    # 拷贝 sys.config (给 prod 模式)
    Copy-Item -Path (Join-Path $AgentDir "config\sys.config") `
              -Destination (Join-Path $ErlBin "config\sys.config") -Force

    Write-Host "[make] ==> 完成. 已安装 OTP apps + config:"
    Get-ChildItem -Path $ErlBin | ForEach-Object { Write-Host "    $($_.Name)" }
    Write-Host "[make] ==> 启动: .\make.ps1 run  (开发模式, `$env:MODE='prod'; .\make.ps1 run 是发布模式)"
    Write-Host "[make] ==> 停止: .\make.ps1 stop"
}

# 启动 Agent 大脑 (前台运行, 优化参数, Ctrl+C 退出)
function Invoke-Run {
    $startBat = Join-Path $BinDir "start.bat"
    if (-not (Test-Path $startBat)) {
        throw "未找到 $startBat, 请先执行: .\make.ps1 bin"
    }
    & $startBat
}

# 优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)
function Invoke-Stop {
    $stopBat = Join-Path $BinDir "stop.bat"
    if (-not (Test-Path $stopBat)) {
        throw "未找到 $stopBat, 请先执行: .\make.ps1 bin"
    }
    & $stopBat
}

# eunit 测试
function Invoke-Test {
    Push-Location $AgentDir
    try {
        & rebar3 eunit
        if ($LASTEXITCODE -ne 0) { throw "rebar3 eunit 失败 (exit $LASTEXITCODE)" }
    }
    finally { Pop-Location }
}

# 清理编译产物与 bin\erl_bin\
function Invoke-Clean {
    Write-Host "[make] ==> 清理 bin\erl_bin 与 rebar3 build..."
    if (Test-Path $ErlBin) { Remove-Item -Recurse -Force $ErlBin }
    Push-Location $AgentDir
    try {
        & rebar3 clean
    }
    finally { Pop-Location }
    Write-Host "[make] ==> 完成."
}

function Show-Help {
    Write-Host "用法: .\make.ps1 <target>"
    Write-Host ""
    Write-Host "目标:"
    Write-Host "  bin      准备 bin\ 目录骨架 (创建子目录 + 拷贝 .bat 脚本, 不编译产物)"
    Write-Host "  env      检查并安装本地 SDK (Erlang 29 / Go 1.26 / Node.js / rebar3 / wails3) 到 bin\env\"
    Write-Host "  agent    编译 Agent-brains (Erlang/OTP), 产物安装到 bin\erl_bin\"
    Write-Host "  run      启动 Agent 大脑 (前台, 优化参数, Ctrl+C 退出)"
    Write-Host "  stop     优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)"
    Write-Host "  clean    清理编译产物与 bin\erl_bin\"
    Write-Host "  test     跑 eunit 测试"
    Write-Host "  help     显示此帮助"
    Write-Host ""
    Write-Host "模式切换 (run 时):"
    Write-Host "  `$env:MODE='prod'; .\make.ps1 run   # 发布模式"
}

# 自动加载本地 env (若 make env 已生成 activate.ps1), 让后续 target 复用 bin\env 下的工具
$activatePs1 = Join-Path $EnvDir "activate.ps1"
if ((Test-Path $activatePs1) -and $Target -ne "env") {
    . $activatePs1
}

# === 目标分发 ===
switch ($Target) {
    "bin"    { Invoke-Bin }
    "env"    { Invoke-Env }
    "agent"  { Invoke-Agent }
    "run"    { Invoke-Run }
    "stop"   { Invoke-Stop }
    "clean"  { Invoke-Clean }
    "test"   { Invoke-Test }
    "help"   { Show-Help }
    ""       { Show-Help }
    default  { Write-Host "未知目标: $Target (可用: bin / env / agent / run / stop / clean / test / help)"; exit 1 }
}
