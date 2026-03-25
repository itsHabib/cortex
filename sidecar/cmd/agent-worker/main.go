// Package main is the entrypoint for the Cortex agent worker.
//
// The agent worker polls the sidecar's HTTP API for tasks, runs
// `claude -p "prompt"` for each task, and posts the result back.
// It's the "brain" that sits alongside the sidecar in a pod.
//
// Usage:
//
//	SIDECAR_URL=http://localhost:9091 agent-worker
//
// Environment:
//
//	SIDECAR_URL       - Sidecar HTTP API URL (default: http://localhost:9091)
//	POLL_INTERVAL_MS  - Polling interval in ms (default: 500)
//	CLAUDE_COMMAND    - Command to run (default: claude). Set to "mock" for
//	                    built-in mock mode that returns canned output without
//	                    any external dependencies (CI-friendly).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	sidecarURL := envOr("SIDECAR_URL", "http://localhost:9091")
	pollInterval := envDurationMs("POLL_INTERVAL_MS", 500)
	claudeCmd := envOr("CLAUDE_COMMAND", "claude")

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	logger.Info("agent-worker starting",
		"sidecar_url", sidecarURL,
		"poll_interval", pollInterval,
		"claude_command", claudeCmd,
	)

	// Wait for sidecar to be healthy
	if err := waitForSidecar(sidecarURL, 30*time.Second, logger); err != nil {
		logger.Error("sidecar not available", "error", err)
		os.Exit(1)
	}
	logger.Info("sidecar is healthy")

	// Trap signals for graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Poll loop
	for {
		select {
		case <-stop:
			logger.Info("shutting down")
			return
		default:
		}

		task, err := pollTask(sidecarURL)
		if err != nil {
			logger.Debug("poll failed", "error", err)
			time.Sleep(pollInterval)
			continue
		}

		if task == nil {
			time.Sleep(pollInterval)
			continue
		}

		logger.Info("received task", "task_id", task.TaskID)

		// Run task — mock mode returns canned output, otherwise runs claude -p
		start := time.Now()
		var (
			cr      *claudeResult
			runErr  error
		)
		if claudeCmd == "mock" {
			cr = mockResult(task.Prompt)
			logger.Info("mock agent completed", "task_id", task.TaskID)
		} else {
			cr, runErr = runClaude(claudeCmd, task.Prompt)
		}
		duration := time.Since(start)

		if runErr != nil {
			logger.Error("claude failed", "task_id", task.TaskID, "error", runErr, "duration", duration)
			errResult := &claudeResult{ResultText: fmt.Sprintf("claude error: %v", runErr)}
			submitResult(sidecarURL, task.TaskID, "failed", errResult, duration, logger)
		} else {
			logger.Info("claude completed",
				"task_id", task.TaskID,
				"duration", duration,
				"input_tokens", cr.InputTokens,
				"output_tokens", cr.OutputTokens,
				"cost_usd", cr.CostUSD,
			)
			submitResult(sidecarURL, task.TaskID, "completed", cr, duration, logger)
		}
	}
}

// --- Task polling ---

type taskResponse struct {
	Task *taskInfo `json:"task"`
}

type taskInfo struct {
	TaskID    string `json:"task_id"`
	Prompt    string `json:"prompt"`
	Tools     []string `json:"tools"`
	TimeoutMs int64  `json:"timeout_ms"`
}

// pollTask fetches the next pending task from the sidecar.
// Returns nil, nil when no task is available.
func pollTask(sidecarURL string) (*taskInfo, error) {
	resp, err := http.Get(sidecarURL + "/task")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result taskResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if result.Task == nil || result.Task.TaskID == "" {
		return nil, nil
	}

	return result.Task, nil
}

// --- Claude execution ---

// claudeResult holds the parsed output from a claude stream-json run.
type claudeResult struct {
	ResultText string
	InputTokens int
	OutputTokens int
	CacheReadTokens int
	CacheCreationTokens int
	NumTurns int
	CostUSD float64
	SessionID string
}

// runClaude executes the claude CLI with the given prompt and parses NDJSON output.
func runClaude(command string, prompt string) (*claudeResult, error) {
	cmd := exec.Command(command, "-p", prompt, "--output-format", "stream-json", "--verbose")

	// Capture stderr for error diagnostics while also piping to container logs.
	var stderrBuf bytes.Buffer
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderrBuf)

	// claude -p buffers all NDJSON output until exit, so we collect
	// it all at once and parse token counts from the final output.
	output, err := cmd.Output()
	if err != nil {
		stderr := strings.TrimSpace(stderrBuf.String())
		if stderr != "" {
			return nil, fmt.Errorf("command failed: %w; stderr: %s", err, stderr)
		}
		return nil, fmt.Errorf("command failed: %w", err)
	}

	result := &claudeResult{}
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			continue
		}
		processEvent(event, result)
	}

	return result, nil
}

// processEvent extracts fields from a single NDJSON event into the result.
func processEvent(event map[string]any, result *claudeResult) {
	eventType, _ := event["type"].(string)

	switch eventType {
	case "result":
		if r, ok := event["result"].(string); ok {
			result.ResultText = r
		}
		if v, ok := event["cost_usd"].(float64); ok {
			result.CostUSD = v
		}
		if v, ok := event["num_turns"].(float64); ok {
			result.NumTurns = int(v)
		}
		if v, ok := event["session_id"].(string); ok {
			result.SessionID = v
		}
		if usage, ok := event["usage"].(map[string]any); ok {
			extractUsage(usage, result)
		}

	case "system":
		if sid, ok := event["session_id"].(string); ok {
			result.SessionID = sid
		}

	case "assistant":
		if msg, ok := event["message"].(map[string]any); ok {
			if usage, ok := msg["usage"].(map[string]any); ok {
				extractUsage(usage, result)
			}
		}
	}
}

// mockResult returns a canned result that mimics real Claude output.
// Used when CLAUDE_COMMAND=mock for CI-friendly e2e testing without an API key.
func mockResult(prompt string) *claudeResult {
	summary := prompt
	if len(summary) > 80 {
		summary = summary[:80] + "..."
	}
	return &claudeResult{
		ResultText:          fmt.Sprintf("Mock agent completed task: %s", summary),
		InputTokens:         150,
		OutputTokens:        75,
		CacheReadTokens:     0,
		CacheCreationTokens: 0,
		NumTurns:            1,
		CostUSD:             0.001,
		SessionID:           fmt.Sprintf("mock-session-%d", time.Now().UnixNano()),
	}
}

// extractUsage pulls token counts from a usage map into the result.
func extractUsage(usage map[string]any, result *claudeResult) {
	if v, ok := usage["input_tokens"].(float64); ok {
		result.InputTokens = int(v)
	}
	if v, ok := usage["output_tokens"].(float64); ok {
		result.OutputTokens = int(v)
	}
	if v, ok := usage["cache_read_input_tokens"].(float64); ok {
		result.CacheReadTokens = int(v)
	}
	if v, ok := usage["cache_creation_input_tokens"].(float64); ok {
		result.CacheCreationTokens = int(v)
	}
}

// --- Result submission ---

type resultPayload struct {
	TaskID              string  `json:"task_id"`
	Status              string  `json:"status"`
	ResultText          string  `json:"result_text"`
	DurationMs          int64   `json:"duration_ms"`
	InputTokens         int     `json:"input_tokens"`
	OutputTokens        int     `json:"output_tokens"`
	CacheReadTokens     int     `json:"cache_read_tokens"`
	CacheCreationTokens int     `json:"cache_creation_tokens"`
	NumTurns            int     `json:"num_turns"`
	CostUSD             float64 `json:"cost_usd"`
	SessionID           string  `json:"session_id,omitempty"`
}

// submitResult posts the task result back to the sidecar's HTTP API.
func submitResult(sidecarURL string, taskID string, status string, cr *claudeResult, duration time.Duration, logger *slog.Logger) {
	payload := resultPayload{
		TaskID:              taskID,
		Status:              status,
		ResultText:          cr.ResultText,
		DurationMs:          duration.Milliseconds(),
		InputTokens:         cr.InputTokens,
		OutputTokens:        cr.OutputTokens,
		CacheReadTokens:     cr.CacheReadTokens,
		CacheCreationTokens: cr.CacheCreationTokens,
		NumTurns:            cr.NumTurns,
		CostUSD:             cr.CostUSD,
		SessionID:           cr.SessionID,
	}
	body, _ := json.Marshal(payload)

	resp, err := http.Post(sidecarURL+"/task/result", "application/json", bytes.NewReader(body))
	if err != nil {
		logger.Error("failed to submit result", "task_id", taskID, "error", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		logger.Error("submit result failed", "task_id", taskID, "status", resp.StatusCode, "body", string(respBody))
	} else {
		logger.Info("result submitted", "task_id", taskID, "status", status)
	}
}

// --- Sidecar health ---

// waitForSidecar polls the sidecar health endpoint until it responds 200 or the timeout expires.
func waitForSidecar(sidecarURL string, timeout time.Duration, logger *slog.Logger) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(sidecarURL + "/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		logger.Debug("waiting for sidecar...")
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("sidecar not healthy after %s", timeout)
}

// --- Env helpers ---

// envOr returns the environment variable value or fallback if unset/empty.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envDurationMs reads an integer millisecond value from an env var and returns it as a Duration.
func envDurationMs(key string, fallbackMs int) time.Duration {
	if v := os.Getenv(key); v != "" {
		if ms, err := strconv.Atoi(v); err == nil {
			return time.Duration(ms) * time.Millisecond
		}
	}
	return time.Duration(fallbackMs) * time.Millisecond
}
