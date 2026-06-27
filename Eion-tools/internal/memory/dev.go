package memory

import (
	"context"
	"fmt"
	"math"
	"sort"
	"sync"

	"github.com/cloudwego/eino/components/embedding"
	"github.com/google/uuid"
)

// DevBackend 进程内向量库：mock/OpenAI Embedding + 暴力余弦检索。
// 适用于 Windows 本地开发（普通 Redis 无 RediSearch 时）。
type DevBackend struct {
	cfg   Config
	embed embedding.Embedder
	mu    sync.RWMutex
	docs  []devDoc
}

type devDoc struct {
	id        string
	sessionID string
	content   string
	metadata  map[string]any
	vector    []float64
}

// NewDevBackend 创建内存向量后端。
func NewDevBackend(ctx context.Context, cfg Config) (*DevBackend, error) {
	emb, err := buildEmbedder(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &DevBackend{cfg: cfg, embed: emb}, nil
}

func (d *DevBackend) Store(ctx context.Context, sessionID, text string, metadata map[string]any, docID string) (string, error) {
	if sessionID == "" {
		return "", fmt.Errorf("session_id required")
	}
	if text == "" {
		return "", fmt.Errorf("text required")
	}
	if docID == "" {
		docID = uuid.NewString()
	}
	vecs, err := d.embed.EmbedStrings(ctx, []string{text})
	if err != nil {
		return "", err
	}
	if len(vecs) != 1 {
		return "", fmt.Errorf("unexpected embed length %d", len(vecs))
	}
	meta := map[string]any{}
	for k, v := range metadata {
		meta[k] = v
	}
	doc := devDoc{
		id:        docID,
		sessionID: sessionID,
		content:   text,
		metadata:  meta,
		vector:    vecs[0],
	}
	d.mu.Lock()
	d.docs = append(d.docs, doc)
	d.mu.Unlock()
	return docID, nil
}

func (d *DevBackend) Search(ctx context.Context, query, sessionID string, topK int) ([]SearchHit, error) {
	if query == "" {
		return nil, fmt.Errorf("query required")
	}
	if topK <= 0 {
		topK = 5
	}
	vecs, err := d.embed.EmbedStrings(ctx, []string{query})
	if err != nil {
		return nil, err
	}
	qv := vecs[0]

	d.mu.RLock()
	defer d.mu.RUnlock()

	type scored struct {
		doc   devDoc
		score float64
	}
	var candidates []scored
	for _, doc := range d.docs {
		if sessionID != "" && doc.sessionID != sessionID {
			continue
		}
		candidates = append(candidates, scored{doc: doc, score: cosineSim(qv, doc.vector)})
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].score > candidates[j].score
	})
	if len(candidates) > topK {
		candidates = candidates[:topK]
	}
	hits := make([]SearchHit, 0, len(candidates))
	for _, c := range candidates {
		hits = append(hits, SearchHit{
			ID:        c.doc.id,
			Content:   c.doc.content,
			SessionID: c.doc.sessionID,
			Metadata:  c.doc.metadata,
		})
	}
	return hits, nil
}

func cosineSim(a, b []float64) float64 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		dot += a[i] * b[i]
		na += a[i] * a[i]
		nb += b[i] * b[i]
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}
