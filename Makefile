# Makefile - Hermes Agent 大脑构建与运行
#
# 目标:
#   make bin        准备 bin/ 目录骨架 (创建子目录 + 脚本可执行权限, 不编译产物)
#   make agent      编译 Agent-brains (Erlang/OTP), 产物安装到 bin/erl_bin/
#   make run        启动 Agent 大脑 (前台, 优化参数, Ctrl+C 退出)
#   make stop       优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)
#   make clean      清理编译产物与 bin/erl_bin/
#   make test       跑 eunit 测试

ROOT_DIR  := $(shell pwd)
AGENT_DIR := $(ROOT_DIR)/Agent-brains
ERL_BIN    := $(ROOT_DIR)/bin/erl_bin
EION_BIN  := $(ROOT_DIR)/bin/eion_bin
WAILS_BIN := $(ROOT_DIR)/bin/wails_v3_bin

.PHONY: bin agent run stop clean test

# 准备 bin/ 目录骨架 (创建子目录 + 确保 .sh 脚本可执行)
# 不编译任何产物, 只搭骨架. 编译产物用:
#   make agent                    -> bin/erl_bin/    (Erlang/OTP)
#   cd Wails-v3 && wails3 build   -> bin/wails_v3_bin/ (Wails v3)
bin:
	@echo "[make] ==> 准备 bin/ 目录结构..."
	@mkdir -p $(ROOT_DIR)/bin
	@mkdir -p $(ERL_BIN) $(EION_BIN) $(WAILS_BIN)
	@chmod +x $(ROOT_DIR)/bin/*.sh 2>/dev/null || true
	@echo "[make] ==> 目录结构 (bin/ 下):"
	@find $(ROOT_DIR)/bin -maxdepth 1 -mindepth 1 | sed 's/^/    /'
	@echo "[make] ==> 脚本 (.sh / .bat):"
	@ls -1 $(ROOT_DIR)/bin/*.sh $(ROOT_DIR)/bin/*.bat 2>/dev/null | sed 's/.*bin\//    /' || echo "    (无)"
	@echo "[make] ==> 完成. 编译产物:"
	@echo "    make agent                    # Erlang -> bin/erl_bin/"
	@echo "    cd Wails-v3 && wails3 build   # Wails  -> bin/wails_v3_bin/"
	@echo "[make] ==> 启动 (二选一, 不可同时运行):"
	@echo "    make run                      # 纯命令行模式 (Erlang, 无 GUI)"
	@echo "    ./bin/start-wails.sh          # 桌面面板模式 (Wails 自动拉起 Erlang)"

# 编译 Agent 大脑 (Erlang/OTP), 产物安装到 bin/erl_bin/
# 拷贝 _build/default/lib/ (含 hermes_brains + deps) + config/sys.config (给 prod 模式)
agent:
	@echo "[make] ==> 编译 Agent-brains..."
	@cd $(AGENT_DIR) && rebar3 compile
	@echo "[make] ==> 安装 beams 到 $(ERL_BIN)..."
	@rm -rf $(ERL_BIN)
	@mkdir -p $(ERL_BIN)/config
	@cp -R $(AGENT_DIR)/_build/default/lib/. $(ERL_BIN)/
	@cp $(AGENT_DIR)/config/sys.config $(ERL_BIN)/config/sys.config
	@echo "[make] ==> 完成. 已安装 OTP apps + config:"
	@ls $(ERL_BIN) | sed 's/^/    /'
	@echo "[make] ==> 启动: make run  (开发模式, MODE=prod make run 是发布模式)"
	@echo "[make] ==> 停止: make stop"

# 启动 Agent 大脑 (前台运行, 优化参数, Ctrl+C 退出)
run:
	@$(ROOT_DIR)/bin/start.sh

# 优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)
stop:
	@$(ROOT_DIR)/bin/stop.sh

# eunit 测试
test:
	@cd $(AGENT_DIR) && rebar3 eunit

clean:
	@echo "[make] ==> 清理 bin/erl_bin 与 rebar3 build..."
	@rm -rf $(ERL_BIN)
	@cd $(AGENT_DIR) && rebar3 clean
	@echo "[make] ==> 完成."
