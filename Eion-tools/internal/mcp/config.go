package mcp

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

const envServersJSON = "HERMES_MCP_SERVERS_JSON"

type ServerConfig struct {
	Name           string            `json:"name"`
	Command        string            `json:"command"`
	Args           []string          `json:"args"`
	Cwd            string            `json:"cwd"`
	Env            map[string]string `json:"env"`
	Enabled        bool              `json:"enabled"`
	ConnectTimeout time.Duration     `json:"-"`
	RetryDelay     time.Duration     `json:"-"`
}

type rawServerConfig struct {
	Name             string            `json:"name"`
	Command          string            `json:"command"`
	Args             []string          `json:"args"`
	Cwd              string            `json:"cwd"`
	Env              map[string]string `json:"env"`
	Enabled          *bool             `json:"enabled"`
	ConnectTimeoutMS int               `json:"connect_timeout_ms"`
	RetryDelayMS     int               `json:"retry_delay_ms"`
}

func LoadConfigsFromEnv() ([]ServerConfig, error) {
	raw := strings.TrimSpace(os.Getenv(envServersJSON))
	if raw == "" {
		return nil, nil
	}
	var items []rawServerConfig
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil, fmt.Errorf("parse %s: %w", envServersJSON, err)
	}
	out := make([]ServerConfig, 0, len(items))
	for _, item := range items {
		cfg := ServerConfig{
			Name:           strings.TrimSpace(item.Name),
			Command:        strings.TrimSpace(item.Command),
			Args:           append([]string(nil), item.Args...),
			Cwd:            strings.TrimSpace(item.Cwd),
			Env:            cloneEnv(item.Env),
			Enabled:        true,
			ConnectTimeout: durationOrDefault(item.ConnectTimeoutMS, 5*time.Second),
			RetryDelay:     durationOrDefault(item.RetryDelayMS, 2*time.Second),
		}
		if item.Enabled != nil {
			cfg.Enabled = *item.Enabled
		}
		if err := cfg.Validate(); err != nil {
			return nil, err
		}
		if cfg.Enabled {
			out = append(out, cfg)
		}
	}
	return out, nil
}

func (c ServerConfig) Validate() error {
	if c.Name == "" {
		return fmt.Errorf("mcp server name is empty")
	}
	if c.Command == "" {
		return fmt.Errorf("mcp server %q command is empty", c.Name)
	}
	return nil
}

func durationOrDefault(ms int, fallback time.Duration) time.Duration {
	if ms <= 0 {
		return fallback
	}
	return time.Duration(ms) * time.Millisecond
}

func cloneEnv(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
