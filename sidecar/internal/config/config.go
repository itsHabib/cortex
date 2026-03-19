// Package config provides configuration loading and validation for the Cortex sidecar.
package config

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/kelseyhightower/envconfig"
)

var agentNameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

// Config holds all sidecar configuration, read from environment variables.
type Config struct {
	GatewayURL        string        `envconfig:"CORTEX_GATEWAY_URL" required:"true"`
	AgentName         string        `envconfig:"CORTEX_AGENT_NAME" required:"true"`
	AgentRole         string        `envconfig:"CORTEX_AGENT_ROLE" default:"agent"`
	AgentCapabilities []string      `envconfig:"CORTEX_AGENT_CAPABILITIES"`
	AuthToken         string        `envconfig:"CORTEX_AUTH_TOKEN"`
	SidecarPort       int           `envconfig:"CORTEX_SIDECAR_PORT" default:"9090"`
	HeartbeatInterval time.Duration `envconfig:"CORTEX_HEARTBEAT_INTERVAL" default:"15s"`
}

// Load reads configuration from environment variables and validates it.
func Load() (*Config, error) {
	var cfg Config
	if err := envconfig.Process("", &cfg); err != nil {
		return nil, fmt.Errorf("config: failed to process environment: %w", err)
	}

	// Trim whitespace from capabilities parsed by envconfig.
	cleaned := make([]string, 0, len(cfg.AgentCapabilities))
	for _, c := range cfg.AgentCapabilities {
		c = strings.TrimSpace(c)
		if c != "" {
			cleaned = append(cleaned, c)
		}
	}
	cfg.AgentCapabilities = cleaned

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// Validate checks semantic rules beyond what envconfig tags express.
func (c *Config) Validate() error {
	var errs []string

	if c.GatewayURL == "" {
		errs = append(errs, "CORTEX_GATEWAY_URL is required")
	}

	if c.AgentName == "" {
		errs = append(errs, "CORTEX_AGENT_NAME is required")
	} else if !agentNameRe.MatchString(c.AgentName) {
		errs = append(errs, "CORTEX_AGENT_NAME must match ^[a-zA-Z0-9_-]+$")
	}

	if c.SidecarPort < 1024 || c.SidecarPort > 65535 {
		errs = append(errs, fmt.Sprintf("CORTEX_SIDECAR_PORT must be between 1024 and 65535, got %d", c.SidecarPort))
	}

	if c.HeartbeatInterval < time.Second {
		errs = append(errs, fmt.Sprintf("CORTEX_HEARTBEAT_INTERVAL must be >= 1s, got %s", c.HeartbeatInterval))
	}

	if len(errs) > 0 {
		return fmt.Errorf("config: validation failed: %s", strings.Join(errs, "; "))
	}
	return nil
}
