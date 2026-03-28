// Package e2e contains high-level end-to-end tests for the K8s spawn backend.
//
// These tests exercise the full orchestration flow with Kubernetes pods:
//
//  1. Makefile creates a kind cluster, loads images, deploys Cortex
//  2. Go test POSTs a multi-team DAG config with backend: k8s
//  3. Cortex auto-spawns K8s Pods (sidecar + worker) per team
//  4. Workers complete tasks (mock by default)
//  5. Poll until run completes
//  6. Verify all agent pods cleaned up
//
// Run:
//
//	make e2e-k8s-simple   # mock agent (no API key needed)
//	make e2e-k8s-multi    # 3-team DAG
package e2e

import (
	"fmt"
	"testing"
	"time"
)

const (
	k8sDAGRunName = "e2e-k8s-dag"
)

// TestK8sDAGSimple runs a single-team DAG with backend: k8s.
// This is the minimal smoke test for the K8s spawn path.
//
// Prerequisite: kind cluster with Cortex deployed (make e2e-k8s-setup),
// port-forward active on localhost:4000/4001.
func TestK8sDAGSimple(t *testing.T) {
	kc := newK8sClient()
	if !kc.available() {
		t.Skipf("kind cluster %s not available (is kind installed? run make e2e-k8s-setup)", k8sContext)
	}

	cleanupK8sPods(kc, t)

	if err := waitForCortexK8s(45 * time.Second); err != nil {
		t.Fatalf("Cortex not ready (is port-forward active?): %v", err)
	}
	t.Log("Cortex is up")

	// Submit a single-team DAG with backend: k8s
	configYAML := fmt.Sprintf(`name: "%s"
defaults:
  model: haiku
  max_turns: 5
  permission_mode: bypassPermissions
  timeout_minutes: 3
  provider: external
  backend: k8s
teams:
  - name: k8s-worker-1
    lead:
      role: "Worker"
    tasks:
      - summary: "E2E k8s smoke test task"
    depends_on: []
`, k8sDAGRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created run: %s", runID)

	// Verify K8s pods were spawned
	time.Sleep(10 * time.Second)
	assertK8sPodsSpawned(t, kc, 1)

	// Wait for run completion
	finalStatus, err := waitForRunCompletion(runID, 120*time.Second)
	if err != nil {
		dumpK8sPodState(t, kc)
		t.Fatalf("Run did not complete: %v", err)
	}

	t.Logf("Run final status: %s", finalStatus)
	assertK8sPodsCleanedUp(t, kc)
}

// TestK8sDAGMultiTeam runs a 5-team, 3-tier DAG with backend: k8s.
// Exercises parallel fan-out (tier 0: 3 teams), fan-in (tier 1: 1 team),
// and a final synthesis (tier 2: 1 team).
//
// Prerequisite: kind cluster with Cortex deployed (make e2e-k8s-setup),
// port-forward active on localhost:4000/4001.
func TestK8sDAGMultiTeam(t *testing.T) {
	kc := newK8sClient()
	if !kc.available() {
		t.Skipf("kind cluster %s not available (is kind installed? run make e2e-k8s-setup)", k8sContext)
	}

	cleanupK8sPods(kc, t)

	if err := waitForCortexK8s(45 * time.Second); err != nil {
		t.Fatalf("Cortex not ready (is port-forward active?): %v", err)
	}
	t.Log("Cortex is up")

	configYAML := fmt.Sprintf(`name: "%s-multi"
defaults:
  model: haiku
  max_turns: 20
  permission_mode: bypassPermissions
  timeout_minutes: 8
  provider: external
  backend: k8s
teams:
  # --- Tier 0: Three parallel research teams ---
  - name: api-researcher
    lead:
      role: "API Design Researcher"
    tasks:
      - summary: "Research REST API design patterns for a task management system"
        details: |
          Research best practices for REST API design applied to a task
          management system. Cover: resource naming for tasks/projects/users,
          filtering and pagination patterns, bulk operations, and webhook
          design for status change notifications. Produce a concise summary
          of recommendations (~20 lines).
        deliverables:
          - "api-patterns.md"
    depends_on: []

  - name: data-modeler
    lead:
      role: "Data Architect"
    tasks:
      - summary: "Design a database schema for a task management system"
        details: |
          Design a PostgreSQL schema for a task management system. Include
          tables for: projects, tasks (with status, priority, assignee),
          comments, labels (M2M), and an activity log. Define primary keys,
          foreign keys, indexes for common queries (tasks by project,
          tasks by assignee, overdue tasks). Include an ASCII ER diagram.
          Keep the output to ~30 lines.
        deliverables:
          - "schema.md"
    depends_on: []

  - name: security-reviewer
    lead:
      role: "Security Engineer"
    tasks:
      - summary: "Define security requirements for a task management API"
        details: |
          Produce a lightweight threat model for a task management API.
          Cover: authentication (JWT with refresh tokens), authorization
          (project-level RBAC: owner/member/viewer), input validation rules,
          rate limiting strategy, and audit logging for sensitive operations.
          List the top 5 threats and their mitigations. Keep it to ~25 lines.
        deliverables:
          - "security.md"
    depends_on: []

  # --- Tier 1: Architecture synthesizes all research ---
  - name: architect
    lead:
      role: "Software Architect"
    tasks:
      - summary: "Design the system architecture based on upstream research"
        details: |
          Based on the API research, data model, and security review from
          upstream teams, design the application architecture. Define:
          package/module structure, layer boundaries (handler -> service ->
          repository), middleware chain (auth, rate-limit, logging),
          configuration management, and error handling strategy. Include
          a component diagram in ASCII. Keep it to ~40 lines.
        deliverables:
          - "architecture.md"
    depends_on: [api-researcher, data-modeler, security-reviewer]

  # --- Tier 2: Implementation plan depends on architecture ---
  - name: tech-lead
    lead:
      role: "Tech Lead"
    tasks:
      - summary: "Produce the implementation plan and launch checklist"
        details: |
          Synthesize all upstream deliverables into a final implementation
          plan. Include: file-by-file breakdown with implementation order,
          test strategy (unit/integration/e2e with specific test cases),
          CI/CD pipeline definition, and a launch checklist with go/no-go
          criteria. Reference specific decisions from each upstream team.
          Keep it to ~50 lines.
        deliverables:
          - "implementation-plan.md"
    depends_on: [architect]
`, k8sDAGRunName)

	runID := createDAGRun(t, configYAML)
	t.Logf("Created 5-team DAG run: %s", runID)

	// Wait a bit and check for tier 0 pods (3 parallel research teams)
	time.Sleep(15 * time.Second)
	pods, _ := kc.listPods(k8sLabelAll)
	t.Logf("Pods active during tier 0: %d", len(pods))
	for _, pod := range pods {
		metadata, _ := pod["metadata"].(map[string]any)
		labels, _ := metadata["labels"].(map[string]any)
		status, _ := pod["status"].(map[string]any)
		phase, _ := status["phase"].(string)
		t.Logf("  team=%v run-id=%v phase=%v", labels["cortex.dev/team"], labels["cortex.dev/run-id"], phase)
	}

	// Wait for run completion (longer timeout for 3-tier DAG)
	finalStatus, err := waitForRunCompletion(runID, 300*time.Second)
	if err != nil {
		dumpK8sPodState(t, kc)
		t.Fatalf("5-team DAG did not complete: %v", err)
	}

	t.Logf("5-team DAG final status: %s", finalStatus)
	assertK8sPodsCleanedUp(t, kc)
}
