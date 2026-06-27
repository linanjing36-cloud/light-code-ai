package memory

import "context"

// Backend 长期记忆存储抽象（Redis Stack 或本地 dev 内存实现）。
type Backend interface {
	Store(ctx context.Context, sessionID, text string, metadata map[string]any, docID string) (string, error)
	Search(ctx context.Context, query, sessionID string, topK int) ([]SearchHit, error)
	DeleteSession(ctx context.Context, sessionID string) (int, error)
}

// SearchHit 检索命中项。
type SearchHit struct {
	ID        string         `json:"id"`
	Content   string         `json:"content"`
	SessionID string         `json:"session_id,omitempty"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}
