package config

import (
	"os"
	"testing"
	"time"
)

// setEnv sets the required env vars for a valid config and returns a cleanup function.
func setEnv(t *testing.T, overrides map[string]string) {
	t.Helper()
	defaults := map[string]string{
		"CORTEX_GATEWAY_URL": "localhost:4001",
		"CORTEX_AGENT_NAME":  "test-agent",
	}
	for k, v := range overrides {
		defaults[k] = v
	}
	for k, v := range defaults {
		t.Setenv(k, v)
	}
}

func clearEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"CORTEX_GATEWAY_URL",
		"CORTEX_AGENT_NAME",
		"CORTEX_AGENT_ROLE",
		"CORTEX_AGENT_CAPABILITIES",
		"CORTEX_AUTH_TOKEN",
		"CORTEX_SIDECAR_PORT",
		"CORTEX_HEARTBEAT_INTERVAL",
	} {
		os.Unsetenv(key)
	}
}

func TestLoad(t *testing.T) {
	tests := []struct {
		name      string
		env       map[string]string
		wantErr   bool
		errMsg    string
		check     func(t *testing.T, cfg *Config)
	}{
		{
			name: "valid config with all fields",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":        "cortex:4001",
				"CORTEX_AGENT_NAME":         "my-agent",
				"CORTEX_AGENT_ROLE":         "reviewer",
				"CORTEX_AGENT_CAPABILITIES": "review,analyze",
				"CORTEX_AUTH_TOKEN":          "secret",
				"CORTEX_SIDECAR_PORT":       "8080",
				"CORTEX_HEARTBEAT_INTERVAL": "10s",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.GatewayURL != "cortex:4001" {
					t.Errorf("GatewayURL = %q, want %q", cfg.GatewayURL, "cortex:4001")
				}
				if cfg.AgentName != "my-agent" {
					t.Errorf("AgentName = %q, want %q", cfg.AgentName, "my-agent")
				}
				if cfg.AgentRole != "reviewer" {
					t.Errorf("AgentRole = %q, want %q", cfg.AgentRole, "reviewer")
				}
				if len(cfg.AgentCapabilities) != 2 || cfg.AgentCapabilities[0] != "review" || cfg.AgentCapabilities[1] != "analyze" {
					t.Errorf("AgentCapabilities = %v, want [review analyze]", cfg.AgentCapabilities)
				}
				if cfg.AuthToken != "secret" {
					t.Errorf("AuthToken = %q, want %q", cfg.AuthToken, "secret")
				}
				if cfg.SidecarPort != 8080 {
					t.Errorf("SidecarPort = %d, want %d", cfg.SidecarPort, 8080)
				}
				if cfg.HeartbeatInterval != 10*time.Second {
					t.Errorf("HeartbeatInterval = %s, want %s", cfg.HeartbeatInterval, 10*time.Second)
				}
			},
		},
		{
			name: "defaults applied",
			env: map[string]string{
				"CORTEX_GATEWAY_URL": "cortex:4001",
				"CORTEX_AGENT_NAME":  "test-agent",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.AgentRole != "agent" {
					t.Errorf("AgentRole = %q, want default %q", cfg.AgentRole, "agent")
				}
				if cfg.SidecarPort != 9090 {
					t.Errorf("SidecarPort = %d, want default %d", cfg.SidecarPort, 9090)
				}
				if cfg.HeartbeatInterval != 15*time.Second {
					t.Errorf("HeartbeatInterval = %s, want default %s", cfg.HeartbeatInterval, 15*time.Second)
				}
			},
		},
		{
			name:    "missing gateway URL",
			env:     map[string]string{"CORTEX_AGENT_NAME": "test-agent"},
			wantErr: true,
			errMsg:  "CORTEX_GATEWAY_URL",
		},
		{
			name:    "missing agent name",
			env:     map[string]string{"CORTEX_GATEWAY_URL": "cortex:4001"},
			wantErr: true,
			errMsg:  "CORTEX_AGENT_NAME",
		},
		{
			name: "invalid agent name with spaces",
			env: map[string]string{
				"CORTEX_GATEWAY_URL": "cortex:4001",
				"CORTEX_AGENT_NAME":  "bad name here",
			},
			wantErr: true,
			errMsg:  "must match",
		},
		{
			name: "invalid agent name with special chars",
			env: map[string]string{
				"CORTEX_GATEWAY_URL": "cortex:4001",
				"CORTEX_AGENT_NAME":  "agent@host",
			},
			wantErr: true,
			errMsg:  "must match",
		},
		{
			name: "port too low",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":  "cortex:4001",
				"CORTEX_AGENT_NAME":   "test-agent",
				"CORTEX_SIDECAR_PORT": "80",
			},
			wantErr: true,
			errMsg:  "between 1024 and 65535",
		},
		{
			name: "port too high",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":  "cortex:4001",
				"CORTEX_AGENT_NAME":   "test-agent",
				"CORTEX_SIDECAR_PORT": "99999",
			},
			wantErr: true,
			errMsg:  "between 1024 and 65535",
		},
		{
			name: "heartbeat interval too low",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":        "cortex:4001",
				"CORTEX_AGENT_NAME":         "test-agent",
				"CORTEX_HEARTBEAT_INTERVAL": "500ms",
			},
			wantErr: true,
			errMsg:  ">= 1s",
		},
		{
			name: "capabilities parsing with spaces",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":        "cortex:4001",
				"CORTEX_AGENT_NAME":         "test-agent",
				"CORTEX_AGENT_CAPABILITIES": "a, b, c",
			},
			check: func(t *testing.T, cfg *Config) {
				want := []string{"a", "b", "c"}
				if len(cfg.AgentCapabilities) != len(want) {
					t.Fatalf("AgentCapabilities length = %d, want %d", len(cfg.AgentCapabilities), len(want))
				}
				for i, v := range want {
					if cfg.AgentCapabilities[i] != v {
						t.Errorf("AgentCapabilities[%d] = %q, want %q", i, cfg.AgentCapabilities[i], v)
					}
				}
			},
		},
		{
			name: "single capability",
			env: map[string]string{
				"CORTEX_GATEWAY_URL":        "cortex:4001",
				"CORTEX_AGENT_NAME":         "test-agent",
				"CORTEX_AGENT_CAPABILITIES": "single",
			},
			check: func(t *testing.T, cfg *Config) {
				if len(cfg.AgentCapabilities) != 1 || cfg.AgentCapabilities[0] != "single" {
					t.Errorf("AgentCapabilities = %v, want [single]", cfg.AgentCapabilities)
				}
			},
		},
		{
			name: "valid agent name with underscores and hyphens",
			env: map[string]string{
				"CORTEX_GATEWAY_URL": "cortex:4001",
				"CORTEX_AGENT_NAME":  "my_agent-01",
			},
			check: func(t *testing.T, cfg *Config) {
				if cfg.AgentName != "my_agent-01" {
					t.Errorf("AgentName = %q, want %q", cfg.AgentName, "my_agent-01")
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			cfg, err := Load()
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errMsg != "" {
					if !contains(err.Error(), tt.errMsg) {
						t.Errorf("error %q does not contain %q", err.Error(), tt.errMsg)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.check != nil {
				tt.check(t, cfg)
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchSubstring(s, substr)
}

func searchSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
