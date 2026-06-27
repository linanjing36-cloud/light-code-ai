package memory

import (
	"context"
	"os"
	"testing"
)

func TestDevBackend_StoreAndSearch(t *testing.T) {
	os.Setenv("HERMES_MEMORY_MOCK_EMBED", "1")
	os.Setenv("HERMES_EMBEDDING_DIM", "64")
	cfg := LoadConfig()
	cfg.Backend = "dev"

	ctx := context.Background()
	svc, err := NewDevBackend(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	sess := "dev-test"
	text := "我最喜欢的编程语言是 Erlang"
	id, err := svc.Store(ctx, sess, text, nil, "")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	if id == "" {
		t.Fatal("empty id")
	}
	hits, err := svc.Search(ctx, "编程语言", sess, 3)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(hits) == 0 {
		t.Fatal("no hits")
	}
	if hits[0].Content != text {
		t.Fatalf("unexpected hit: %+v", hits[0])
	}
}
