package memory

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"math"

	"github.com/cloudwego/eino/components/embedding"
)

// mockEmbedder 确定性伪向量，用于本地 Redis 联调（无需真实 Embedding API）。
// 设置 HERMES_MEMORY_MOCK_EMBED=1 启用。
type mockEmbedder struct {
	dim int
}

func newMockEmbedder(dim int) embedding.Embedder {
	return &mockEmbedder{dim: dim}
}

func (m *mockEmbedder) EmbedStrings(_ context.Context, texts []string, _ ...embedding.Option) ([][]float64, error) {
	out := make([][]float64, len(texts))
	for i, text := range texts {
		out[i] = hashToVector(text, m.dim)
	}
	return out, nil
}

func (m *mockEmbedder) GetType() string { return "MockHash" }

func (m *mockEmbedder) IsCallbacksEnabled() bool { return false }

func hashToVector(text string, dim int) []float64 {
	sum := sha256.Sum256([]byte(text))
	vec := make([]float64, dim)
	for i := 0; i < dim; i++ {
		idx := i % len(sum)
		next := (idx + 1) % len(sum)
		raw := binary.BigEndian.Uint16([]byte{sum[idx], sum[next]})
		vec[i] = float64(raw)/65535.0*2 - 1
	}
	var norm float64
	for _, v := range vec {
		norm += v * v
	}
	norm = math.Sqrt(norm)
	if norm > 0 {
		for i := range vec {
			vec[i] /= norm
		}
	}
	return vec
}
