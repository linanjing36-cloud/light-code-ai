package server

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"

	"github.com/light-code-ai/eion-tools/internal/dispatcher"
	"github.com/light-code-ai/eion-tools/internal/logging"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

func runFramingLoop(r io.Reader, w io.Writer, d *dispatcher.Command_Dispatcher) error {
	for {
		req, err := readFrame(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("read frame: %w", err)
		}
		logging.Logger.Info("received frame", zap.Int("bytes", len(req)))

		agentReq := &hermes.AgentRequest{}
		if err := proto.Unmarshal(req, agentReq); err != nil {
			logging.Logger.Error("unmarshal failed", zap.Error(err))
			errResp := &hermes.AgentResponse{
				Payload: &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{
						Error: fmt.Sprintf("decode request: %v", err),
					},
				},
			}
			if err := writeAgentFrame(w, errResp); err != nil {
				return fmt.Errorf("write error frame: %w", err)
			}
			continue
		}

		switch p := agentReq.GetPayload().(type) {
		case *hermes.AgentRequest_LlmInfer:
			logging.Logger.Debug("dispatch: llm_infer",
				zap.String("model", p.LlmInfer.GetModel()),
				zap.Int("msgs", len(p.LlmInfer.GetMessages())),
				zap.Int("tools", len(p.LlmInfer.GetTools())),
				zap.Bool("stream", p.LlmInfer.GetStream()),
			)
		case *hermes.AgentRequest_ToolExec:
			logging.Logger.Debug("dispatch: tool_exec",
				zap.String("name", p.ToolExec.GetToolName()),
				zap.String("req_id", p.ToolExec.GetReqId()),
			)
		case *hermes.AgentRequest_ToolList:
			logging.Logger.Debug("dispatch: tool_list")
		case *hermes.AgentRequest_CapabilityList:
			logging.Logger.Debug("dispatch: capability_list")
		}

		writeAgent := func(resp *hermes.AgentResponse) error {
			logging.Logger.Debug("sending response frame", zap.Int("bytes", proto.Size(resp)))
			return writeAgentFrame(w, resp)
		}

		if err := d.DispatchStream(context.Background(), agentReq, writeAgent); err != nil {
			return fmt.Errorf("write frame: %w", err)
		}
	}
}

func readFrame(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 {
		return []byte{}, nil
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeFrame(w io.Writer, msg proto.Message) error {
	buf, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal response: %w", err)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(buf)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	if _, err := w.Write(buf); err != nil {
		return err
	}
	if f, ok := w.(interface{ Sync() error }); ok {
		_ = f.Sync()
	}
	return nil
}

func writeAgentFrame(w io.Writer, resp *hermes.AgentResponse) error {
	return writeFrame(w, resp)
}
