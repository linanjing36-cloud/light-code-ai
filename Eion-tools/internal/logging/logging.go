// Package logging 提供进程级 zap 结构化日志器。
//
// 该服务作为 Erlang 端口子进程运行：stdin/stdout 是 {packet,4} framed
// protobuf 通信通道，因此日志器必须只写入 stderr，绝不能写入 stdout。
package logging

import (
	"os"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// Logger 是进程共享的 zap 日志器，由 Init 初始化。
// 未调用 Init 前为 nil；cmd/server/main.go 入口会最先调用 Init。
var Logger *zap.Logger

// Init 初始化全局 zap 日志器：JSON 编码、Debug 级别、输出到 stderr。
//
// 使用 zapcore.AddSync(os.Stderr) 作为写同步器，确保日志绝不污染 stdout
// （stdout 保留给与 Erlang 的 framed protobuf 通信）。
func Init() {
	encoderConfig := zap.NewProductionEncoderConfig()
	encoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	core := zapcore.NewCore(
		zapcore.NewJSONEncoder(encoderConfig),
		zapcore.AddSync(os.Stderr),
		zapcore.DebugLevel,
	)
	Logger = zap.New(core)
}
