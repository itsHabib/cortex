// Package e2e contains end-to-end tests for the Cortex ExternalAgent pipeline.
//
// These tests exercise the full flow:
//
//	Go sidecar ↔ gRPC ↔ Gateway.Registry ↔ ExternalAgent ↔ Provider.External ↔ Executor
//
// The test starts everything itself — Cortex server, Go sidecar, task poller —
// and tears it all down on completion. No manual setup required.
//
// Run:
//
//	make e2e
//	# or: cd e2e && go test -v -timeout 120s
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

const (
	cortexAPI    = "http://localhost:4000/api"
	grpcAddr     = "localhost:4001"
	sidecarPort  = "9092"
	sidecarHTTP  = "http://localhost:9092"
	authToken    = "e2e-test-token"
	agentName    = "e2e-go-agent"
	pollInterval = 200 * time.Millisecond
)

func projectRoot() string {
	// e2e/ is one level below the project root
	return filepath.Join("..")
}

func sidecarBin() string {
	return filepath.Join(projectRoot(), "sidecar", "bin", "cortex-sidecar")
}

func workerBin() string {
	return filepath.Join(projectRoot(), "sidecar", "bin", "agent-worker")
}

// TestExternalAgentE2E tests the full pipeline:
//  1. Start Cortex server (mix phx.server)
//  2. Start Go sidecar → registers in Gateway via gRPC
//  3. POST /api/runs with provider: external config → triggers Runner.run
//  4. Poller goroutine auto-responds to tasks via sidecar HTTP API
//  5. Poll GET /api/runs/:id until completed
//  6. Assert run completed successfully
func TestExternalAgentE2E(t *testing.T) {
	// Check binaries exist
	if _, err := os.Stat(sidecarBin()); err != nil {
		t.Fatalf("Sidecar binary not found at %s. Run: cd sidecar && make build", sidecarBin())
	}
	if _, err := os.Stat(workerBin()); err != nil {
		t.Fatalf("Agent-worker binary not found at %s. Run: make worker-build", workerBin())
	}

	// --- Start Cortex ---
	cortex, err := startCortex(t)
	if err != nil {
		t.Fatalf("Failed to start Cortex: %v", err)
	}
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(30 * time.Second); err != nil {
		t.Fatalf("Cortex did not start: %v", err)
	}
	t.Log("Cortex is up")

	// --- Start sidecar ---
	sidecar, err := startSidecar(t)
	if err != nil {
		t.Fatalf("Failed to start sidecar: %v", err)
	}
	defer stopProcess(sidecar, "Sidecar", t)

	if err := waitForSidecarHealth(30 * time.Second); err != nil {
		t.Fatalf("Sidecar did not become healthy: %v", err)
	}
	t.Log("Sidecar is healthy and connected")

	// --- Start agent-worker ---
	claudeCommand := ""
	if os.Getenv("USE_CLAUDE") == "" {
		mockScript := createMockClaudeScript(t)
		defer os.Remove(mockScript)
		claudeCommand = mockScript
		t.Log("Using mock claude (set USE_CLAUDE=1 for real Claude)")
	} else {
		t.Log("Using real Claude (USE_CLAUDE=1)")
	}

	worker, err := startWorker(t, claudeCommand)
	if err != nil {
		t.Fatalf("Failed to start agent-worker: %v", err)
	}
	defer stopProcess(worker, "Agent-worker", t)

	// --- Create and trigger a run ---
	runID, err := createRun(t)
	if err != nil {
		t.Fatalf("Failed to create run: %v", err)
	}
	t.Logf("Created run: %s", runID)

	// --- Wait for run to complete ---
	runTimeout := 60 * time.Second
	if os.Getenv("USE_CLAUDE") != "" {
		runTimeout = 180 * time.Second
	}
	finalStatus, err := waitForRunCompletion(runID, runTimeout)
	if err != nil {
		t.Fatalf("Run did not complete: %v", err)
	}

	t.Logf("Run final status: %s", finalStatus)

	if finalStatus != "completed" {
		t.Errorf("Expected run status 'completed', got '%s'", finalStatus)
	}
}

// --- Process management ---

func startCortex(t *testing.T) (*exec.Cmd, error) {
	cmd := exec.Command("mix", "phx.server")
	cmd.Dir = projectRoot()
	cmd.Env = append(os.Environ(),
		"CORTEX_GATEWAY_TOKEN="+authToken,
		"MIX_ENV=dev",
	)
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start cortex: %w", err)
	}

	t.Logf("Cortex started (PID %d)", cmd.Process.Pid)
	return cmd, nil
}

func startSidecar(t *testing.T) (*exec.Cmd, error) {
	cmd := exec.Command(sidecarBin())
	cmd.Env = append(os.Environ(),
		"CORTEX_GATEWAY_URL="+grpcAddr,
		"CORTEX_AGENT_NAME="+agentName,
		"CORTEX_AGENT_ROLE=e2e-test-worker",
		"CORTEX_AGENT_CAPABILITIES=testing,e2e",
		"CORTEX_AUTH_TOKEN="+authToken,
		"CORTEX_SIDECAR_PORT="+sidecarPort,
	)
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start sidecar: %w", err)
	}

	t.Logf("Sidecar started (PID %d)", cmd.Process.Pid)
	return cmd, nil
}

func stopProcess(cmd *exec.Cmd, name string, t *testing.T) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Logf("%s stopped", name)
	}
}

func waitForCortex(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(cortexAPI + "/runs?limit=1")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("cortex not ready after %s", timeout)
}

func waitForSidecarHealth(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(sidecarHTTP + "/health")
		if err == nil {
			var health struct {
				Connected bool   `json:"connected"`
				Status    string `json:"status"`
				AgentID   string `json:"agent_id"`
			}
			if json.NewDecoder(resp.Body).Decode(&health) == nil && health.Connected && health.AgentID != "" {
				resp.Body.Close()
				return nil
			}
			resp.Body.Close()
		}
		time.Sleep(pollInterval)
	}
	return fmt.Errorf("sidecar not healthy after %s", timeout)
}

// --- Cortex API ---

func createRun(t *testing.T) (string, error) {
	configYAML := fmt.Sprintf(`name: "e2e-external-test"
defaults:
  model: sonnet
  max_turns: 10
  permission_mode: acceptEdits
  timeout_minutes: 5
  provider: external
teams:
  - name: %s
    lead:
      role: "Worker"
    tasks:
      - summary: "E2E test task"
    depends_on: []
`, agentName)

	body, _ := json.Marshal(map[string]string{
		"name":        "e2e-external-test",
		"config_yaml": configYAML,
	})

	resp, err := http.Post(cortexAPI+"/runs", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("POST /api/runs: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("POST /api/runs returned %d: %s", resp.StatusCode, string(respBody))
	}

	var result struct {
		Data struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}

	t.Logf("Run created: id=%s status=%s", result.Data.ID, result.Data.Status)
	return result.Data.ID, nil
}

func waitForRunCompletion(runID string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(fmt.Sprintf("%s/runs/%s", cortexAPI, runID))
		if err != nil {
			time.Sleep(pollInterval)
			continue
		}

		var result struct {
			Data struct {
				Status string `json:"status"`
			} `json:"data"`
		}
		if json.NewDecoder(resp.Body).Decode(&result) == nil {
			status := result.Data.Status
			if status == "completed" || status == "failed" {
				resp.Body.Close()
				return status, nil
			}
		}
		resp.Body.Close()
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("run %s did not finish within %s", runID, timeout)
}

// --- Agent worker ---

// startWorker starts the agent-worker binary. If claudeCommand is empty,
// it uses the default "claude" CLI.
func startWorker(t *testing.T, claudeCommand string) (*exec.Cmd, error) {
	cmd := exec.Command(workerBin())
	env := append(os.Environ(),
		"SIDECAR_URL="+sidecarHTTP,
		"POLL_INTERVAL_MS=200",
	)
	if claudeCommand != "" {
		env = append(env, "CLAUDE_COMMAND="+claudeCommand)
	}
	cmd.Env = env
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start agent-worker: %w", err)
	}

	t.Logf("Agent-worker started (PID %d)", cmd.Process.Pid)
	return cmd, nil
}

func createMockClaudeScript(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "mock-claude.sh")
	content := `#!/bin/bash
# Mock claude script for e2e testing.
# Ignores all args, outputs a fixed response.
echo "E2E test: task completed successfully by agent-worker"
`
	if err := os.WriteFile(script, []byte(content), 0o755); err != nil {
		t.Fatalf("Failed to create mock claude script: %v", err)
	}
	return script
}
