// Package e2e contains high-level end-to-end tests for the Docker spawn backend.
//
// These tests exercise the full orchestration flow with Docker containers:
//
//  1. Build the cortex-agent-worker combo image
//  2. Start Cortex server
//  3. POST a multi-team DAG config with backend: docker
//  4. Cortex auto-spawns Docker containers (sidecar + worker) per team
//  5. Workers complete tasks (mock by default, real Claude with USE_CLAUDE=1)
//  6. Poll until run completes
//  7. Verify all containers cleaned up
//
// Run:
//
//	make e2e-docker-dag                 # mock agent (no API key needed)
//	USE_CLAUDE=1 make e2e-docker-dag    # real Claude agent
//	# or: cd e2e && go test -v -run TestDockerDAG -timeout 300s
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const (
	comboImage   = "cortex-agent-worker:latest"
	dagRunName   = "e2e-docker-dag"
	dagAuthToken = "e2e-docker-dag-token"
)

// TestDockerDAGSimple runs a single-team DAG with backend: docker.
// This is the minimal smoke test for the Docker spawn path.
func TestDockerDAGSimple(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}

	ensureComboImage(t)
	cleanupCortexContainers(d, t)

	cortex := startCortexForDocker(t)
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(45 * time.Second); err != nil {
		t.Fatalf("Cortex did not start: %v", err)
	}
	t.Log("Cortex is up")

	// Submit a single-team DAG with backend: docker
	configYAML := fmt.Sprintf(`name: "%s"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
  provider: external
  backend: docker
teams:
  - name: docker-worker-1
    lead:
      role: "Worker"
    tasks:
      - summary: "E2E docker smoke test task"
    depends_on: []
`, dagRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created run: %s", runID)

	// Verify Docker containers were spawned
	time.Sleep(5 * time.Second)
	assertContainersSpawned(t, d, 1)

	// Wait for run completion
	finalStatus, err := waitForRunCompletion(runID, 120*time.Second)
	if err != nil {
		dumpContainerState(t, d)
		t.Fatalf("Run did not complete: %v", err)
	}

	t.Logf("Run final status: %s", finalStatus)
	assertContainersCleanedUp(t, d)
}

// TestDockerDAGMultiTeam runs a 3-team DAG with backend: docker.
// Teams are in two tiers to test parallel + sequential execution with Docker.
func TestDockerDAGMultiTeam(t *testing.T) {
	d := newDockerClient()
	if err := d.ping(); err != nil {
		t.Skipf("Docker not available: %v", err)
	}

	ensureComboImage(t)
	cleanupCortexContainers(d, t)

	cortex := startCortexForDocker(t)
	defer stopProcess(cortex, "Cortex", t)

	if err := waitForCortex(45 * time.Second); err != nil {
		t.Fatalf("Cortex did not start: %v", err)
	}
	t.Log("Cortex is up")

	// 3-team DAG: researcher + analyst (tier 1, parallel), writer (tier 2, depends on both)
	configYAML := fmt.Sprintf(`name: "%s-multi"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 5
  provider: external
  backend: docker
teams:
  - name: researcher
    lead:
      role: "Researcher"
    tasks:
      - summary: "Research task for e2e"
    depends_on: []
  - name: analyst
    lead:
      role: "Analyst"
    tasks:
      - summary: "Analysis task for e2e"
    depends_on: []
  - name: writer
    lead:
      role: "Writer"
    tasks:
      - summary: "Writing task using research and analysis"
    depends_on: [researcher, analyst]
`, dagRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created 3-team DAG run: %s", runID)

	// Wait a bit and check for tier 1 containers (researcher + analyst)
	time.Sleep(8 * time.Second)
	containers, _ := d.listContainers("cortex.managed=true")
	t.Logf("Containers active during tier 1: %d", len(containers))
	for _, c := range containers {
		labels, _ := c["Labels"].(map[string]any)
		state, _ := c["State"].(string)
		t.Logf("  role=%v team=%v state=%v", labels["cortex.role"], labels["cortex.team"], state)
	}

	// Wait for run completion
	finalStatus, err := waitForRunCompletion(runID, 180*time.Second)
	if err != nil {
		dumpContainerState(t, d)
		t.Fatalf("3-team DAG did not complete: %v", err)
	}

	t.Logf("3-team DAG final status: %s", finalStatus)
	assertContainersCleanedUp(t, d)
}

// -- Helpers --

func ensureComboImage(t *testing.T) {
	t.Helper()

	d := newDockerClient()
	resp, err := d.do("GET", "/images/"+comboImage+"/json", nil)
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode == 200 {
			t.Log("Combo image exists")
			return
		}
	}

	t.Log("Building cortex-agent-worker combo image...")
	cmd := exec.Command("docker", "build",
		"-t", comboImage,
		"-f", "Dockerfile.combo",
		".",
	)
	cmd.Dir = projectRoot() + "/sidecar"
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to build combo image: %v", err)
	}
	t.Log("Combo image built")
}

func startCortexForDocker(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("mix", "phx.server")
	cmd.Dir = projectRoot()

	// Default to mock agent (no API key needed). USE_CLAUDE=1 for real Claude.
	claudeCommand := "mock"
	if os.Getenv("USE_CLAUDE") != "" {
		claudeCommand = "claude"
		t.Log("Using real Claude (USE_CLAUDE=1)")
	} else {
		t.Log("Using mock agent (set USE_CLAUDE=1 for real Claude)")
	}

	cmd.Env = append(os.Environ(),
		"CORTEX_GATEWAY_TOKEN="+dagAuthToken,
		"MIX_ENV=dev",
		"CLAUDE_COMMAND="+claudeCommand,
		"CLAUDE_MODEL=haiku",
		"CLAUDE_MAX_TURNS=3",
		"CLAUDE_PERMISSION_MODE=bypassPermissions",
	)
	if testing.Verbose() {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start Cortex: %v", err)
	}
	t.Logf("Cortex started (PID %d, CLAUDE_COMMAND=%s)", cmd.Process.Pid, claudeCommand)
	return cmd
}

func createDAGRun(t *testing.T, configYAML string) string {
	t.Helper()

	name := "e2e-docker-test"
	for _, line := range strings.Split(configYAML, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "name:") {
			name = strings.Trim(strings.TrimPrefix(trimmed, "name:"), " \"'")
			break
		}
	}

	payload, _ := json.Marshal(map[string]string{
		"name":        name,
		"config_yaml": configYAML,
	})

	resp, err := http.Post(cortexAPI+"/runs", "application/json", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("POST /api/runs: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /api/runs returned %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Data struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("Decode response: %v", err)
	}

	t.Logf("Run created: id=%s status=%s", result.Data.ID, result.Data.Status)
	return result.Data.ID
}

func assertContainersSpawned(t *testing.T, d *dockerClient, expectedTeams int) {
	t.Helper()
	containers, err := d.listContainers("cortex.managed=true")
	if err != nil {
		t.Fatalf("List containers: %v", err)
	}

	sidecars, workers := 0, 0
	for _, c := range containers {
		labels, ok := c["Labels"].(map[string]any)
		if !ok {
			continue
		}
		switch labels["cortex.role"] {
		case "sidecar":
			sidecars++
			t.Logf("Sidecar: team=%v", labels["cortex.team"])
		case "worker":
			workers++
			t.Logf("Worker: team=%v", labels["cortex.team"])
		}
	}

	t.Logf("Containers spawned: %d sidecars, %d workers (expected %d teams)", sidecars, workers, expectedTeams)
	if sidecars < expectedTeams {
		t.Errorf("Expected >= %d sidecar containers, found %d", expectedTeams, sidecars)
	}
	if workers < expectedTeams {
		t.Errorf("Expected >= %d worker containers, found %d", expectedTeams, workers)
	}
}

func assertContainersCleanedUp(t *testing.T, d *dockerClient) {
	t.Helper()
	time.Sleep(3 * time.Second) // Give executor time to cleanup
	remaining, err := d.listContainers("cortex.managed=true")
	if err != nil {
		t.Logf("Warning: failed to check remaining containers: %v", err)
		return
	}
	if len(remaining) > 0 {
		t.Logf("WARNING: %d containers remain after run", len(remaining))
		for _, c := range remaining {
			labels, _ := c["Labels"].(map[string]any)
			t.Logf("  Leftover: role=%v team=%v", labels["cortex.role"], labels["cortex.team"])
		}
		cleanupCortexContainers(d, t)
	} else {
		t.Log("All containers cleaned up")
	}
}

func dumpContainerState(t *testing.T, d *dockerClient) {
	t.Helper()
	containers, _ := d.listContainers("cortex.managed=true")
	if len(containers) == 0 {
		t.Log("No cortex containers found")
		return
	}
	for _, c := range containers {
		labels, _ := c["Labels"].(map[string]any)
		state, _ := c["State"].(string)
		id, _ := c["Id"].(string)
		t.Logf("  Container: role=%v team=%v state=%v names=%v",
			labels["cortex.role"], labels["cortex.team"], state, c["Names"])
		if id != "" {
			logs, err := d.containerLogs(id)
			if err == nil && logs != "" {
				// Trim to last 40 lines to keep output manageable
				lines := strings.Split(logs, "\n")
				if len(lines) > 40 {
					lines = lines[len(lines)-40:]
				}
				t.Logf("  --- logs (%s) ---\n%s", labels["cortex.role"], strings.Join(lines, "\n"))
			}
		}
	}
}

func cleanupCortexContainers(d *dockerClient, t *testing.T) {
	t.Helper()
	containers, err := d.listContainers("cortex.managed=true")
	if err != nil {
		return
	}
	for _, c := range containers {
		id, ok := c["Id"].(string)
		if !ok {
			continue
		}
		_ = d.stopContainer(id)
		_ = d.removeContainer(id)
	}
	if len(containers) > 0 {
		t.Logf("Cleaned up %d leftover containers", len(containers))
	}

	// Clean up cortex-* networks (not cortex-net which is from compose)
	resp, err := d.do("GET", "/networks", nil)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	var networks []map[string]any
	if json.NewDecoder(resp.Body).Decode(&networks) == nil {
		for _, net := range networks {
			name, _ := net["Name"].(string)
			id, _ := net["Id"].(string)
			if strings.HasPrefix(name, "cortex-") && name != "cortex-net" {
				_ = d.removeNetwork(id)
			}
		}
	}
}
