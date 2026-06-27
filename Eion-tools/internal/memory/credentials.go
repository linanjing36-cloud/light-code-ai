package memory

import (
	"encoding/json"
	"os"
)

type credentialsFile struct {
	APIKey           string `json:"api_key"`
	EmbeddingModel   string `json:"embedding_model"`
	EmbeddingAPIBase string `json:"embedding_api_base"`
}

func loadCredentialsFile() (credentialsFile, error) {
	path := os.Getenv("API_KEY_FILE")
	if path == "" {
		for _, p := range []string{"api-key.json", "../api-key.json", "../../api-key.json"} {
			if _, err := os.Stat(p); err == nil {
				path = p
				break
			}
		}
	}
	if path == "" {
		return credentialsFile{}, os.ErrNotExist
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return credentialsFile{}, err
	}
	var c credentialsFile
	if err := json.Unmarshal(body, &c); err != nil {
		return credentialsFile{}, err
	}
	return c, nil
}
