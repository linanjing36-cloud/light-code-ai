# Hermes Agent

Erlang/OTP 编排大脑 + Go/Eino 执行层 + Wails v3 桌面面板的三进程架构。各进程独立启动，通过 `bin/run/*.addr` 端口文件互相发现。

## 编译产物目录

| 目录 | 内容 |
|------|------|
| `bin/erl_bin/` | Agent-brains（Erlang beam + deps + config） |
| `bin/eion_bin/` | Eion-tools 服务端（`eion-tools-server.exe`） |
| `bin/wails_v3_bin/` | Wails 桌面面板（`hermes.exe`） |
| `bin/env/` | 本地 SDK（由 `make env` 安装，可选） |

---

## Windows 编译

使用仓库根目录的 `make.ps1`（PowerShell）。

### 1. 准备环境（首次）

```powershell
.\make.ps1 env      # 检测并安装 Erlang 29 / Go 1.26 / Node.js / protoc / rebar3 / protoc-gen-go / wails3 到 bin\env\
.\make.ps1 bin      # 创建 bin\ 目录骨架，拷贝启动脚本
```

若系统已安装所需工具，可跳过 `env`。后续 `make.ps1` 会自动加载 `bin\env\activate.ps1`（若存在）。
如果后续需要重新生成 `Wails-v3\proto\gen\panelpb\`，可先用 `protoc --version` 与 `protoc-gen-go --version` 验证代码生成工具是否已就绪。

### 2. 编译三个组件

```powershell
.\make.ps1 tools      # Eion-tools  -> bin\eion_bin\eion-tools-server.exe
.\make.ps1 agent      # Agent-brains -> bin\erl_bin\
.\make.ps1 wails_v3   # Wails-v3     -> bin\wails_v3_bin\hermes.exe
```

首次执行 `wails_v3` 时，若缺少 `Wails-v3\build\`，会自动运行 `wails3 generate build-assets` 生成构建资产。

### 3. 其他命令

```powershell
.\make.ps1 test       # 运行 Agent-brains eunit 测试
.\make.ps1 clean      # 清理 bin\erl_bin\ 与 rebar3 编译缓存
.\make.ps1 help       # 显示帮助
```

---

## Linux / macOS 编译

使用 `Makefile`（Erlang 部分）。Go 与 Wails 需手动编译：

```bash
make bin              # 准备 bin/ 目录骨架
make agent            # Agent-brains -> bin/erl_bin/

# Eion-tools
cd Eion-tools && go build -o ../bin/eion_bin/eion-tools-server ./cmd/server

# Wails-v3（需已安装 wails3、Node.js）
cd Wails-v3 && wails3 build    # 产出 bin/wails_v3_bin/hermes
```

---

## 启动

三进程必须**按顺序**启动，各自独立窗口/终端：

```
Eion-tools  ──▶  Agent-brains  ──▶  Wails GUI
 (tools)          (agent)            (wails_v3)
```

### Windows（桌面面板模式）

```powershell
.\bin\start-tools.bat    # 1. 启动 Eion-tools，写入 bin\run\eion-tools.addr
.\bin\start-agent.bat    # 2. 启动 Erlang 大脑，写入 bin\run\panel.addr
.\bin\start-wails.bat    # 3. 启动 Wails 面板，读取 panel.addr 连接大脑
```

停止：

```powershell
.\bin\stop-wails.bat     # 关闭 Wails 窗口，或运行此脚本
.\bin\stop.bat           # 优雅停止 Erlang（rpc init:stop）
                         # Eion-tools 在其窗口 Ctrl+C 退出
```

### Windows（纯命令行模式，无 GUI）

仅需 Erlang 大脑，不启动 Wails：

```powershell
.\bin\start-tools.bat
.\bin\start-agent.bat
# 或合并入口：
.\make.ps1 run           # 开发模式（默认 MODE=dev）
$env:MODE='prod'; .\make.ps1 run   # 发布模式
.\make.ps1 stop          # 优雅停止
```

### Linux / macOS

当前完整的三进程启动脚本（`start-tools` / `start-agent` / `start-wails`）以 Windows `.bat` 为主。Unix 侧可用：

```bash
# 纯命令行模式（Erlang + 内嵌 Eion-tools 路径，无 GUI）
make run                 # 或 ./bin/start.sh
make stop                # 或 ./bin/stop.sh

# 桌面面板（需先编译 Wails）
./bin/start-wails.sh
./bin/stop-wails.sh
```

Eion-tools 与 Wails 的编译见上方「Linux / macOS 编译」一节。

---

## 启动前检查

| 检查项 | 期望路径 |
|--------|----------|
| Eion-tools 已编译 | `bin/eion_bin/eion-tools-server.exe`（Windows） |
| Agent-brains 已编译 | `bin/erl_bin/` 目录存在且含 beam |
| Wails 已编译（GUI 模式） | `bin/wails_v3_bin/hermes.exe`（Windows） |

若启动脚本报错「未找到编译产物」，回到上方编译步骤补跑对应 `make` 目标。
