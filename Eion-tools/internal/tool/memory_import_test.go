package tool

import "testing"

func TestSplitDocument(t *testing.T) {
	chunks := splitDocument("你好世界", 2)
	if len(chunks) != 2 {
		t.Fatalf("expected 2 chunks, got %d", len(chunks))
	}
	if chunks[0] != "你好" || chunks[1] != "世界" {
		t.Fatalf("unexpected chunks: %v", chunks)
	}
	if splitDocument("", 10) != nil {
		t.Fatal("empty text should return nil")
	}
}
