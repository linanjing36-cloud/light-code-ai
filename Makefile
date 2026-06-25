# Makefile - Hermes Agent 大脑构建与运行
#
# 目标:
#   make agent      编译 Agent-brains (Erlang/OTP), 产物安装到 bin/erl_bin/
#   make run        启动 Agent 大脑 (前台, 优化参数, Ctrl+C 退出)
#   make stop       优雅停止 Agent 大脑 (rpc init:stop 触发 app terminate)
#   make clean      清理编译产物与 bin/erl_bin/
#   make test       跑 eunit 测试

ROOT_DIR  := $(shell pwd)
AGENT_DIR := $(ROOT_DIR)/Agent-brains
ERL_BIN   := $(ROOT_DIR)/bin/erl_bin

.PHONY: agent run stop clean test

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
