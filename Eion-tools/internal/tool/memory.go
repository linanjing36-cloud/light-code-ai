package tool

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/light-code-ai/eion-tools/internal/memory"
)

// RegisterMemoryTools 注册 memory_store / memory_search / memory_import 工具。
func RegisterMemoryTools(w *Eino_Tool_Wrapper, svc memory.Backend) {
	name, desc, params, storeH := MemoryStoreHandler(svc)
	w.Register(name, desc, params, storeH)
	name, desc, params, searchH := MemorySearchHandler(svc)
	w.Register(name, desc, params, searchH)
	name, desc, params, importH := MemoryImportHandler(svc)
	w.Register(name, desc, params, importH)
}

// MemoryStoreHandler 将文本片段写入向量库。
func MemoryStoreHandler(svc memory.Backend) (name, description, parametersJSON string, h HandlerFunc) {
	return "memory_store",
		"将一段文本存入长期记忆（向量库），供后续 memory_search 检索。适用于用户明确要求记住的信息、会话中的重要事实。",
		`{"type":"object","properties":{"session_id":{"type":"string","description":"会话 ID，用于隔离不同用户的记忆"},"text":{"type":"string","description":"要记住的文本内容"},"doc_id":{"type":"string","description":"可选，文档 ID；省略则自动生成"},"metadata_json":{"type":"string","description":"可选，额外元数据 JSON 对象字符串"}},"required":["session_id","text"]}`,
		func(ctx context.Context, argumentsJSON string) (string, error) {
			var args struct {
				SessionID    string `json:"session_id"`
				Text         string `json:"text"`
				DocID        string `json:"doc_id"`
				MetadataJSON string `json:"metadata_json"`
			}
			if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
				return "", fmt.Errorf("parse arguments: %w", err)
			}
			meta := map[string]any{}
			if args.MetadataJSON != "" {
				if err := json.Unmarshal([]byte(args.MetadataJSON), &meta); err != nil {
					return "", fmt.Errorf("parse metadata_json: %w", err)
				}
			}
			id, err := svc.Store(ctx, args.SessionID, args.Text, meta, args.DocID)
			if err != nil {
				return "", err
			}
			out, _ := json.Marshal(map[string]string{"doc_id": id, "status": "stored"})
			return string(out), nil
		}
}

// MemorySearchHandler 从向量库语义检索记忆片段。
func MemorySearchHandler(svc memory.Backend) (name, description, parametersJSON string, h HandlerFunc) {
	return "memory_search",
		"从长期记忆（向量库）中检索与查询语义相关的历史片段。可限定 session_id 只搜当前会话。",
		`{"type":"object","properties":{"query":{"type":"string","description":"检索查询，自然语言"},"session_id":{"type":"string","description":"可选，限定在某个会话内检索"},"top_k":{"type":"integer","description":"返回条数，默认 5"}},"required":["query"]}`,
		func(ctx context.Context, argumentsJSON string) (string, error) {
			var args struct {
				Query     string `json:"query"`
				SessionID string `json:"session_id"`
				TopK      int    `json:"top_k"`
			}
			if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
				return "", fmt.Errorf("parse arguments: %w", err)
			}
			hits, err := svc.Search(ctx, args.Query, args.SessionID, args.TopK)
			if err != nil {
				return "", err
			}
			out, err := json.Marshal(map[string]any{"hits": hits, "count": len(hits)})
			if err != nil {
				return "", err
			}
			return string(out), nil
		}
}

// MemoryImportHandler 将长文档分块写入向量库。
func MemoryImportHandler(svc memory.Backend) (name, description, parametersJSON string, h HandlerFunc) {
	return "memory_import",
		"将长文档分块导入长期记忆（向量库），供 memory_search 检索。",
		`{"type":"object","properties":{"session_id":{"type":"string","description":"会话 ID"},"document_text":{"type":"string","description":"完整文档文本"},"chunk_size":{"type":"integer","description":"分块字符数，默认 400"},"source":{"type":"string","description":"可选来源标识"}},"required":["session_id","document_text"]}`,
		func(ctx context.Context, argumentsJSON string) (string, error) {
			var args struct {
				SessionID    string `json:"session_id"`
				DocumentText string `json:"document_text"`
				ChunkSize    int    `json:"chunk_size"`
				Source       string `json:"source"`
			}
			if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
				return "", fmt.Errorf("parse arguments: %w", err)
			}
			chunks := splitDocument(args.DocumentText, args.ChunkSize)
			if len(chunks) == 0 {
				return "", fmt.Errorf("document_text is empty")
			}
			ids := make([]string, 0, len(chunks))
			for i, chunk := range chunks {
				meta := map[string]any{
					"chunk_index": i,
					"chunk_total": len(chunks),
				}
				if args.Source != "" {
					meta["source"] = args.Source
				}
				id, err := svc.Store(ctx, args.SessionID, chunk, meta, "")
				if err != nil {
					return "", err
				}
				ids = append(ids, id)
			}
			out, _ := json.Marshal(map[string]any{
				"status":     "imported",
				"chunks":     len(chunks),
				"doc_ids":    ids,
				"session_id": args.SessionID,
			})
			return string(out), nil
		}
}

func splitDocument(text string, chunkSize int) []string {
	if text == "" {
		return nil
	}
	if chunkSize <= 0 {
		chunkSize = 400
	}
	runes := []rune(text)
	if len(runes) <= chunkSize {
		return []string{text}
	}
	var chunks []string
	for i := 0; i < len(runes); i += chunkSize {
		end := i + chunkSize
		if end > len(runes) {
			end = len(runes)
		}
		chunks = append(chunks, string(runes[i:end]))
	}
	return chunks
}
