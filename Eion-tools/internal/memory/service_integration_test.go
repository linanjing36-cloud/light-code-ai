//go:build integration

package memory

import (
	"context"
	"os"
	"testing"
)

// 联调: HERMES_MEMORY_MOCK_EMBED=1 + Redis Stack 运行后执行
//   go test -tags integration ./internal/memory/... -v
func TestStoreAndSearch_Integration(t *testing.T) {
	if os.Getenv("HERMES_REDIS_ADDR") == "" {
		os.Setenv("HERMES_REDIS_ADDR", "127.0.0.1:6379")
	}
	os.Setenv("HERMES_MEMORY_MOCK_EMBED", "1")
	os.Setenv("HERMES_EMBEDDING_DIM", "64")
	os.Setenv("HERMES_MEMORY_INDEX", "hermes_memory_test")
	os.Setenv("HERMES_MEMORY_KEY_PREFIX", "hermes_mem_test:")

	cfg := LoadConfig()
	ctx := context.Background()
	svc, err := NewService(ctx, cfg)
	if err != nil {
		t.Skipf("redis not available: %v", err)
	}
	sess := "test-session-1"
	text := "我最喜欢的编程语言是 Erlang"
	id, err := svc.Store(ctx, sess, text, nil, "")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	if id == "" {
		t.Fatal("expected doc id")
	}
	hits, err := svc.Search(ctx, "编程语言", sess, 3)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(hits) == 0 {
		t.Fatal("expected at least one hit")
	}
	found := false
	for _, h := range hits {
		if h.Content == text {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected stored text in hits: %+v", hits)
	}
}
