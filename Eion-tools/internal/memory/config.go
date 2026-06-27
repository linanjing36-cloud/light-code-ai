package memory

import (
	"os"
	"strconv"
)

// Config 长期记忆 / RAG 向量库配置（环境变量驱动）。
type Config struct {
	RedisAddr     string
	IndexName     string
	KeyPrefix     string
	EmbeddingDim  int
	EmbeddingModel string
	EmbeddingAPIKey  string
	EmbeddingAPIBase string
	MockEmbed     bool
	Backend       string
	FallbackDev   bool
}

const (
	defaultRedisAddr      = "127.0.0.1:6379"
	defaultIndexName      = "hermes_memory"
	defaultKeyPrefix      = "hermes_mem:"
	defaultEmbeddingDim   = 1536
	defaultEmbeddingModel = "text-embedding-3-small"
	defaultEmbeddingBase  = "https://api.openai.com/v1"
)

// LoadConfig 从环境变量加载配置；Embedding API Key 可来自 HERMES_EMBEDDING_API_KEY 或 api-key.json。
func LoadConfig() Config {
	rawBackend := os.Getenv("HERMES_MEMORY_BACKEND")
	backend := rawBackend
	if backend == "" {
		backend = DefaultBackendForPlatform()
	}
	cfg := Config{
		RedisAddr:        envOr("HERMES_REDIS_ADDR", defaultRedisAddr),
		IndexName:        envOr("HERMES_MEMORY_INDEX", defaultIndexName),
		KeyPrefix:        envOr("HERMES_MEMORY_KEY_PREFIX", defaultKeyPrefix),
		EmbeddingDim:     envIntOr("HERMES_EMBEDDING_DIM", defaultEmbeddingDim),
		EmbeddingModel:   envOr("HERMES_EMBEDDING_MODEL", defaultEmbeddingModel),
		EmbeddingAPIBase: envOr("HERMES_EMBEDDING_API_BASE", defaultEmbeddingBase),
		MockEmbed:        envBool("HERMES_MEMORY_MOCK_EMBED"),
		Backend:          backend,
		FallbackDev:      envBool("HERMES_MEMORY_FALLBACK_DEV") || rawBackend == "auto",
	}
	cfg.EmbeddingAPIKey = os.Getenv("HERMES_EMBEDDING_API_KEY")
	if cfg.EmbeddingAPIKey == "" {
		if cred, err := loadCredentialsFile(); err == nil {
			cfg.EmbeddingAPIKey = cred.APIKey
			if cfg.EmbeddingAPIBase == defaultEmbeddingBase && cred.EmbeddingAPIBase != "" {
				cfg.EmbeddingAPIBase = cred.EmbeddingAPIBase
			}
			if cfg.EmbeddingModel == defaultEmbeddingModel && cred.EmbeddingModel != "" {
				cfg.EmbeddingModel = cred.EmbeddingModel
			}
		}
	}
	return cfg
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envIntOr(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func envBool(key string) bool {
	v := os.Getenv(key)
	return v == "1" || v == "true" || v == "yes"
}
