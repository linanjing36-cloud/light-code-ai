package memory

import (
	"context"
	"fmt"
	"strings"

	openaiEmb "github.com/cloudwego/eino-ext/components/embedding/openai"
	redisIndexer "github.com/cloudwego/eino-ext/components/indexer/redis"
	redisRetriever "github.com/cloudwego/eino-ext/components/retriever/redis"
	"github.com/cloudwego/eino/components/embedding"
	"github.com/cloudwego/eino/components/retriever"
	"github.com/cloudwego/eino/schema"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const fieldSessionID = "session_id"

// Service 封装 Eino Redis Indexer + Retriever（无 Agent 编排）。
type Service struct {
	cfg       Config
	client    *redis.Client
	indexer   *redisIndexer.Indexer
	retriever *redisRetriever.Retriever
}

// NewService 连接 Redis Stack、创建向量索引并装配 Eino 组件。
func NewService(ctx context.Context, cfg Config) (*Service, error) {
	client := redis.NewClient(&redis.Options{
		Addr:          cfg.RedisAddr,
		Protocol:      2,
		UnstableResp3: true,
	})
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping %s: %w", cfg.RedisAddr, err)
	}

	emb, err := buildEmbedder(ctx, cfg)
	if err != nil {
		return nil, err
	}

	if err := ensureIndex(ctx, client, cfg); err != nil {
		return nil, err
	}

	docMapper := func(_ context.Context, doc *schema.Document) (*redisIndexer.Hashes, error) {
		if doc.ID == "" {
			return nil, fmt.Errorf("document id required")
		}
		sessionID, _ := doc.MetaData[fieldSessionID].(string)
		field2Value := map[string]redisIndexer.FieldValue{
			"content": {
				Value:    doc.Content,
				EmbedKey: "vector_content",
			},
			fieldSessionID: {Value: sessionID},
		}
		for k, v := range doc.MetaData {
			if k == fieldSessionID {
				continue
			}
			field2Value[k] = redisIndexer.FieldValue{Value: v}
		}
		return &redisIndexer.Hashes{Key: doc.ID, Field2Value: field2Value}, nil
	}

	idx, err := redisIndexer.NewIndexer(ctx, &redisIndexer.IndexerConfig{
		Client:           client,
		KeyPrefix:        cfg.KeyPrefix,
		BatchSize:        10,
		Embedding:        emb,
		DocumentToHashes: docMapper,
	})
	if err != nil {
		return nil, fmt.Errorf("new indexer: %w", err)
	}

	ret, err := redisRetriever.NewRetriever(ctx, &redisRetriever.RetrieverConfig{
		Client:       client,
		Index:        cfg.IndexName,
		VectorField:  "vector_content",
		TopK:         5,
		Embedding:    emb,
		ReturnFields: []string{"content", fieldSessionID},
	})
	if err != nil {
		return nil, fmt.Errorf("new retriever: %w", err)
	}

	return &Service{cfg: cfg, client: client, indexer: idx, retriever: ret}, nil
}

func buildEmbedder(ctx context.Context, cfg Config) (embedding.Embedder, error) {
	if cfg.MockEmbed {
		return newMockEmbedder(cfg.EmbeddingDim), nil
	}
	if cfg.EmbeddingAPIKey == "" {
		return nil, fmt.Errorf("embedding api key missing: set HERMES_EMBEDDING_API_KEY, API_KEY_FILE, or HERMES_MEMORY_MOCK_EMBED=1")
	}
	dim := cfg.EmbeddingDim
	return openaiEmb.NewEmbedder(ctx, &openaiEmb.EmbeddingConfig{
		APIKey:  cfg.EmbeddingAPIKey,
		BaseURL: cfg.EmbeddingAPIBase,
		Model:   cfg.EmbeddingModel,
		Dimensions: &dim,
	})
}

func ensureIndex(ctx context.Context, client *redis.Client, cfg Config) error {
	schemas := []*redis.FieldSchema{
		{FieldName: "content", FieldType: redis.SearchFieldTypeText, Weight: 1},
		{
			FieldName: "vector_content",
			FieldType: redis.SearchFieldTypeVector,
			VectorArgs: &redis.FTVectorArgs{
				FlatOptions: &redis.FTFlatOptions{
					Type:           "FLOAT32",
					Dim:            cfg.EmbeddingDim,
					DistanceMetric: "COSINE",
				},
			},
		},
		{FieldName: fieldSessionID, FieldType: redis.SearchFieldTypeTag},
	}
	_, err := client.FTCreate(ctx, cfg.IndexName, &redis.FTCreateOptions{
		OnHash: true,
		Prefix: []any{cfg.KeyPrefix},
	}, schemas...).Result()
	if err != nil && !strings.Contains(strings.ToLower(err.Error()), "index already exists") {
		return fmt.Errorf("ft.create %s: %w", cfg.IndexName, err)
	}
	return nil
}

// Store 写入一条会话记忆片段。
func (s *Service) Store(ctx context.Context, sessionID, text string, metadata map[string]any, docID string) (string, error) {
	if sessionID == "" {
		return "", fmt.Errorf("session_id required")
	}
	if text == "" {
		return "", fmt.Errorf("text required")
	}
	if docID == "" {
		docID = uuid.NewString()
	}
	meta := map[string]any{fieldSessionID: sessionID}
	for k, v := range metadata {
		meta[k] = v
	}
	doc := &schema.Document{ID: docID, Content: text, MetaData: meta}
	ids, err := s.indexer.Store(ctx, []*schema.Document{doc})
	if err != nil {
		return "", err
	}
	if len(ids) == 0 {
		return docID, nil
	}
	return ids[0], nil
}

// SearchHit 检索命中项 — 见 backend.go

// Search 语义检索；sessionID 非空时限定会话范围。
func (s *Service) Search(ctx context.Context, query, sessionID string, topK int) ([]SearchHit, error) {
	if query == "" {
		return nil, fmt.Errorf("query required")
	}
	if topK <= 0 {
		topK = 5
	}
	opts := []retriever.Option{
		retriever.WithTopK(topK),
	}
	if sessionID != "" {
		opts = append(opts, redisRetriever.WithFilterQuery(fmt.Sprintf("@%s:{%s}", fieldSessionID, escapeTag(sessionID))))
	}
	docs, err := s.retriever.Retrieve(ctx, query, opts...)
	if err != nil {
		return nil, err
	}
	hits := make([]SearchHit, 0, len(docs))
	for _, d := range docs {
		sid, _ := d.MetaData[fieldSessionID].(string)
		meta := map[string]any{}
		for k, v := range d.MetaData {
			if k != fieldSessionID {
				meta[k] = v
			}
		}
		hits = append(hits, SearchHit{
			ID:        d.ID,
			Content:   d.Content,
			SessionID: sid,
			Metadata:  meta,
		})
	}
	return hits, nil
}

// escapeTag 转义 RediSearch TAG 查询值中的标点（如 session_id 里的 `-`）。
func escapeTag(s string) string {
	special := ",.<>{}[]\"':;!@#$%^&*()-+=~|\\|"
	var b strings.Builder
	for _, r := range s {
		if r == '\\' || strings.ContainsRune(special, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}
