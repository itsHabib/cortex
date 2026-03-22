# Executor Integration QE Plan

## You are in PLAN MODE.

### Project
I want to do a **Phase 3.5 QE -- Executor Integration Hardening**.

**Goal:** Harden the executor-to-ExternalAgent integration path through adversarial testing -- finding bugs, race conditions, and edge cases in `ensure_external_agent`, `run_via_external_agent`, and the ExternalSupervisor lifecycle under stress, then fixing any issues discovered.

### Role + Scope (fill in)
- **Role:** Executor Integration QE
- **Scope:** Adversarial testing of the executor -> ExternalAgent integration path. I own edge-case tests in `test/cortex/orchestration/runner/executor_external_test.exs` and bug fixes in `lib/cortex/orchestration/runner/executor.ex` and `lib/cortex/agent/external_supervisor.ex`. I do NOT own ExternalAgent GenServer internals (PubSub handling, Provider.External delegation), Gateway.Registry, Provider.External, PendingTasks, or sidecar code.
- **File you will write:** `docs/compute-spawning/phase-3.5-external-agent-qe/plans/executor-integration-qe.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** `ensure_external_agent/1` must handle the concurrent-start race: two Task processes calling `ensure_external_agent` for the same `team_name` simultaneously must both succeed (one starts, one gets `{:ok, existing_pid}` via `:already_started` handling). Test must prove this with concurrent tasks.
- **FR2:** When an ExternalAgent process crashes between `ensure_external_agent` returning `{:ok, pid}` and `ExternalAgent.run(pid, ...)` being called, the executor must receive a clean `{:error, reason}` -- not an unhandled exit that kills the Task process.
- **FR3:** When `ExternalSupervisor` is not running (e.g., removed from app tree or crashed), `ensure_external_agent/1` must return `{:error, _}` cleanly, not crash.
- **FR4:** When `Provider.External.start/1` fails inside `ExternalAgent.run/3` (e.g., PendingTasks not running, registry down), the error must propagate cleanly to the executor as `{:error, reason}`.
- **FR5:** When the executor's `Task.await_many` timeout fires before `ExternalAgent.run` returns, the ExternalAgent GenServer must not be left in a broken state -- it should be reusable for subsequent runs.
- **FR6:** When the same `team_name` is reused across multiple DAG runs, the ExternalAgent must not leak state (pending task refs, stale status) from the previous run.
- **FR7:** Verify telemetry events are emitted at the correct points in the external dispatch path (Provider.External dispatched/completed events).
- **Tests required:** 7 adversarial test cases in `executor_external_test.exs`, plus targeted fixes for any bugs found.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+ / OTP 26+
- Local dev: `mix test test/cortex/orchestration/runner/executor_external_test.exs`
- Observability: Verify existing telemetry events fire correctly; no new telemetry needed
- Safety: All error paths must produce clean `{:error, reason}` tuples, never crashes or exits that escape the Task boundary
- Documentation: Tests serve as documentation of edge-case behavior
- Performance: N/A -- these are correctness tests, not performance tests

---

## Assumptions / System Model
- **Deployment environment:** Local development (`mix test`). The executor runs teams in `Task.async` inside `execute_tier/8`.
- **Failure modes under test:**
  - Concurrent calls to `ensure_external_agent/1` for same name (TOCTOU race between `find_agent` and `start_agent`)
  - ExternalAgent process death between pid acquisition and use (stale pid)
  - ExternalSupervisor process not available (`:noproc` from `DynamicSupervisor.start_child`)
  - Provider.External.start failure during ExternalAgent.run (cascading dependency failure)
  - Task.await_many timeout killing the Task process mid-GenServer.call (orphaned GenServer call)
  - Agent state leakage across sequential runs (stale PendingTasks refs, status flags)
- **Delivery guarantees:** At-most-once per test scenario.
- **Multi-tenancy:** None.

---

## Data Model (as relevant to your role)
N/A -- not in scope for this role. QE tests use the existing `Config`, `TeamResult`, `Workspace`, and `ExternalAgent` state structs unchanged. No new data entities.

---

## APIs (as relevant to your role)

### Functions Under Test

All functions are existing -- no new API surface. The QE tests exercise these existing interfaces adversarially:

1. **`Executor.ensure_external_agent/1`** (private, tested indirectly via `Runner.run/2`)
   - Normal: `{:ok, pid}` when agent found or started
   - Race: two concurrent callers for same name both get `{:ok, pid}`
   - Failure: `{:error, :noproc}` when supervisor down, `{:error, :agent_not_found}` when sidecar unregistered

2. **`Executor.run_via_external_agent/3`** (private, tested indirectly)
   - Normal: `{:ok, TeamResult.t()}` on success
   - Stale pid: `{:error, _}` when ExternalAgent crashed between lookup and call
   - Provider failure: `{:error, _}` when Provider.External.start fails

3. **`ExternalSupervisor.start_agent/1`**
   - `:already_started` handling under concurrent calls
   - Clean error when supervisor not running

4. **`ExternalAgent.run/3`**
   - GenServer state after caller (Task process) is killed by Task.await_many timeout
   - State isolation across sequential runs

### Error Semantics

Every adversarial scenario must result in one of:
- `{:error, {:tier_failed, tier_index, [team_name]}}` at the `Runner.run` level
- `{team_name, {:error, reason}, %{type: :error, reason: reason}}` at the outcome tuple level
- Clean recovery with no GenServer state corruption

Never: unhandled `:EXIT`, `Task.await_many` crash propagation, or GenServer stuck in bad state.

---

## Architecture / Component Boundaries (as relevant)

### Components I Test (read: exercise adversarially)

- **Executor.run_team/6** -> `dispatch_to_provider/6` -> `run_via_external_agent/3` -> `ensure_external_agent/1`: The full external dispatch chain from team execution to ExternalAgent invocation.
- **ExternalSupervisor.start_agent/1** and **find_agent/1**: The lookup-or-start logic and its `:already_started` race handling.
- **ExternalAgent.run/3**: The GenServer.call that blocks on Provider.External dispatch.

### Components I May Fix

- **`lib/cortex/orchestration/runner/executor.ex`**: If `run_via_external_agent/3` or `ensure_external_agent/1` don't handle exit signals from crashed ExternalAgent processes, I add a `try/catch :exit` wrapper.
- **`lib/cortex/agent/external_supervisor.ex`**: If `start_agent/1` doesn't handle the case where the supervisor process itself is down, or if `:already_started` handling has a subtle bug.

### What I Don't Touch

- ExternalAgent GenServer internals (PubSub, Provider.External delegation)
- Provider.External, PendingTasks, TaskPush
- Gateway.Registry
- YAML config, application.ex

### Concurrency Analysis

The key concurrency scenario: `execute_tier/8` spawns N `Task.async` processes at line 365. Each Task calls `run_team/6`, which calls `ensure_external_agent/1`. If two teams share a name (not possible in current DAG model, but could happen with misconfigured YAML or future features), or if `ensure_external_agent` is called twice due to a continuation run overlapping with a fresh run, the `find_agent` -> `start_agent` sequence has a TOCTOU window.

Current handling in `ExternalSupervisor.start_agent/1` (line 58-63):
```elixir
case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
  {:ok, pid} -> {:ok, pid}
  {:error, {:already_started, pid}} -> {:ok, pid}
  {:error, reason} -> {:error, unwrap_reason(reason)}
end
```

The `:already_started` clause should handle the race. The QE test will verify this empirically with concurrent Task.async calls.

---

## Correctness Invariants (must be explicit)

1. **Race safety:** Two concurrent `ensure_external_agent("same-name")` calls must both return `{:ok, pid}` pointing to the same ExternalAgent process. Neither call may crash.
2. **Stale pid safety:** If ExternalAgent.run is called with a pid that has since died, the caller receives `{:error, _}` (via `:EXIT` catch or `noproc`), not an unhandled crash.
3. **Supervisor absence safety:** `ensure_external_agent/1` when `ExternalSupervisor` is not running returns `{:error, :noproc}` (or similar), not a crash.
4. **Provider failure propagation:** `Provider.External.start` returning `{:error, reason}` inside `ExternalAgent.run/3` propagates as `{:error, reason}` to the executor, not a GenServer crash.
5. **Task.await_many timeout isolation:** After `Task.await_many` kills a Task process that was mid-`ExternalAgent.run`, the ExternalAgent GenServer remains alive and healthy (`:temporary` restart means no auto-restart on client disconnect).
6. **Cross-run state isolation:** Running `ExternalAgent.run` twice (simulating two DAG runs reusing the same agent) produces correct results for both runs with no stale state leakage.
7. **Telemetry correctness:** `Cortex.Telemetry.emit_gateway_task_dispatched` and `emit_gateway_task_completed` fire during a successful external dispatch.

---

## Tests

### Adversarial Test Cases: `test/cortex/orchestration/runner/executor_external_test.exs`

**Test 1: ensure_external_agent race -- concurrent start for same team_name**
- Spawn two `Task.async` processes that both call `ensure_external_agent` (indirectly, via `Runner.run` with same team_name in two tiers, or by directly testing the race with `ExternalSupervisor.start_agent`).
- Both `find_agent` return `:not_found`, both call `start_agent`.
- Assert both get `{:ok, pid}` with the same pid (one creates, one gets `:already_started`).
- Module: tests `ExternalSupervisor.start_agent/1` concurrency.

**Test 2: ExternalAgent process crash between ensure_external_agent and run**
- Start an ExternalAgent via `ensure_external_agent`.
- Kill the ExternalAgent process (`Process.exit(pid, :kill)`).
- Call `ExternalAgent.run(pid, ...)`.
- Assert the caller gets `{:error, _}` (not an unhandled exit).
- **Potential fix needed:** `run_via_external_agent/3` at executor.ex line 508-516 does not wrap `ExternalAgent.run` in a try/catch. A `GenServer.call` to a dead process raises `** (exit)`. The executor's Task process would crash, and `Task.await_many` would see the exit. This may or may not be handled -- the test will determine if a `try/catch :exit` is needed.

**Test 3: ExternalSupervisor not started -- clean error from ensure_external_agent**
- Stop the ExternalSupervisor (or use a test where it was never started).
- Call the executor with `provider: external`.
- Assert the run returns a clean tier failure, not an unhandled crash.
- **Potential fix needed:** `ensure_external_agent/1` calls `ExternalSupervisor.find_agent` (which calls `AgentRegistry.lookup` -- safe) then `ExternalSupervisor.start_agent` (which calls `DynamicSupervisor.start_child(@supervisor_name, ...)` -- raises if supervisor not running). `start_agent` has no try/catch for this case. The test will determine if `start_agent/1` needs a `:noproc` catch.

**Test 4: Provider.External.start fails inside ExternalAgent.run**
- Register a mock sidecar in Gateway.Registry.
- Start an ExternalAgent.
- Stop the PendingTasks process (so `Provider.External.start` returns `{:error, :registry_not_available}` because `process_alive?` check fails, or a later step fails).
- Call `ExternalAgent.run`.
- Assert the error propagates cleanly to the executor as `{:error, _}`.
- Note: Looking at `Provider.External.start/1` line 77, it checks `process_alive?(registry)`, not `process_alive?(pending_tasks)`. So the failure may come later during `PendingTasks.register_task`. The test will probe the exact failure point.

**Test 5: Task.await_many timeout vs ExternalAgent.run -- GenServer state after caller death**
- Start an ExternalAgent with a mock push_fn that never resolves (simulating a hung sidecar).
- Spawn a Task that calls `ExternalAgent.run` with a long timeout.
- Kill the Task process (simulating `Task.await_many` timeout firing).
- Assert the ExternalAgent GenServer is still alive and in a usable state.
- Call `ExternalAgent.get_state` -- should return `{:ok, %{status: :healthy}}`.
- Call `ExternalAgent.run` again with a resolving push_fn -- should succeed.
- This tests that a GenServer.call from a dead caller doesn't corrupt the GenServer.

**Test 6: Same team_name reused across multiple runs -- no state leakage**
- Run a full DAG execution with `provider: external` and a mock sidecar.
- After completion, run it again with the same team_name.
- Assert both runs complete successfully.
- Assert the second run doesn't see stale task IDs or results from the first run.
- Key concern: `dispatch_via_provider/3` in ExternalAgent builds a fresh Provider.External handle per call (line 248-267), so state leakage should not occur. But the test validates this empirically.

**Test 7: Telemetry events during external dispatch**
- Attach a telemetry handler for `[:cortex, :gateway, :task_dispatched]` and `[:cortex, :gateway, :task_completed]`.
- Run a successful external dispatch.
- Assert both events fire with correct metadata (task_id, agent_id, status).

### Commands

```bash
mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
mix test test/cortex/orchestration/runner/executor_external_test.exs
mix test  # full suite to verify no regressions
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
```

---

## Benchmarks + "Success"
N/A -- This is a QE (quality engineering) plan focused on correctness, not performance. Success is defined by:

1. All 7 adversarial tests pass.
2. Any bugs discovered are fixed with minimal, targeted changes.
3. All existing tests (1367+) continue to pass.
4. `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix credo --strict` all clean.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Test at the Runner.run level (integration) vs. unit-test private functions directly

- **Decision:** Test primarily at the `Runner.run` integration level, supplemented by targeted lower-level tests (ExternalSupervisor concurrency, ExternalAgent state inspection) where the integration path is too coarse.
- **Alternatives considered:**
  1. **Pure unit tests with mocks:** Mock ExternalSupervisor and ExternalAgent, test executor dispatch logic in isolation. Fast but misses the real race conditions and error propagation paths.
  2. **Pure integration tests only:** Run everything through `Runner.run`. Comprehensive but slow, hard to isolate specific failure modes (e.g., can't easily kill an ExternalAgent mid-call through the Runner interface).
- **Why:** The adversarial scenarios (race conditions, crashed processes, missing supervisors) are best tested with real processes, not mocks. But some scenarios (Task.await_many timeout, GenServer state inspection) require reaching below the Runner API. A mix of integration and targeted lower-level tests gives the best coverage-to-isolation tradeoff.
- **Tradeoff acknowledged:** Lower-level tests are coupled to internal implementation details (ExternalSupervisor.start_agent, ExternalAgent.get_state). If internals change, these tests break. Acceptable because the internals are defined by the Phase 3.5 plan and unlikely to change soon.

### Decision 2: Fix bugs in executor.ex/external_supervisor.ex vs. documenting as known issues

- **Decision:** Fix any bugs found during adversarial testing immediately, in the same commit as the test that exposes them.
- **Alternatives considered:**
  1. **Document bugs as GitHub issues, fix later:** Keeps QE scope clean but leaves known bugs unfixed.
  2. **Fix in separate PRs:** Better git history but slower turnaround and risk of regressions between test and fix.
- **Why:** The bugs we expect to find (missing try/catch for `:exit` signals, missing `:noproc` handling) are small, targeted fixes. Shipping the test and fix together ensures the test proves the fix works and prevents regressions.
- **Tradeoff acknowledged:** Mixing test and fix in one commit makes the diff slightly harder to review. Mitigated by keeping fixes minimal and well-commented.

### Decision 3: Simulate Task.await_many timeout via Process.exit vs. actually using Task.await_many with short timeout

- **Decision:** Use `Process.exit(task_pid, :kill)` to simulate the Task.await_many timeout, rather than setting up a real Task.await_many with a short timeout.
- **Alternatives considered:**
  1. **Real Task.await_many with 50ms timeout:** More realistic but introduces timing sensitivity -- the test could flake if the system is slow.
  2. **Mock Task module:** Would require refactoring executor internals to accept an injectable Task module. Too invasive for a QE fix.
- **Why:** `Process.exit(task_pid, :kill)` is deterministic and produces the same effect as `Task.await_many` timing out (the Task process dies, the GenServer.call from it is orphaned). No timing sensitivity, no flaky tests.
- **Tradeoff acknowledged:** Slightly less realistic than the real `Task.await_many` timeout path (which sends `:kill` after a timer). But the GenServer's perspective is identical -- the caller process is dead.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: ExternalAgent.run to a dead process may not be catchable at the executor level

- **Risk:** `ExternalAgent.run(dead_pid, ...)` does `GenServer.call(dead_pid, ...)` which raises `** (exit) {:noproc, {GenServer, :call, [...]}}`. This exit propagates through the Task.async boundary. If `Task.await_many` converts it to `{:exit, reason}` rather than crashing, the executor's `case result do` block at line 473 may not have a matching clause.
- **Impact:** Executor crashes on stale ExternalAgent pid instead of returning a clean error.
- **Mitigation:** Test 2 will expose this. If confirmed, wrap `ExternalAgent.run(pid, prompt, run_opts)` in `run_via_external_agent/3` with a `try/catch :exit, _ -> {:error, :agent_crashed}` guard. Validation: run the test.
- **Validation time:** 5 minutes.

### Risk 2: ExternalSupervisor.start_agent crashes when supervisor is down

- **Risk:** `DynamicSupervisor.start_child(Cortex.Agent.ExternalSupervisor, child_spec)` when the supervisor process doesn't exist raises `** (exit) {:noproc, {GenServer, :call, [...]}}` instead of returning `{:error, :noproc}`.
- **Impact:** `ensure_external_agent` crashes, the Task process dies, tier fails with an opaque exit instead of a clean error.
- **Mitigation:** Test 3 will expose this. If confirmed, add a `try/catch :exit` in `ExternalSupervisor.start_agent/1` or in `ensure_external_agent/1`. The fix is a 3-line change.
- **Validation time:** 5 minutes.

### Risk 3: Test flakiness from PubSub timing

- **Risk:** Tests that rely on PubSub event delivery (e.g., agent_registered broadcast during `register_mock_sidecar`) have `Process.sleep(50)` guards that could be insufficient under load.
- **Impact:** Intermittent test failures in CI.
- **Mitigation:** Use `assert_receive/2` with explicit timeout (100ms) instead of `Process.sleep` where possible. For scenarios where we can't use `assert_receive` (state transitions observed via `get_state`), use a polling helper with exponential backoff up to 200ms.
- **Validation time:** 3 minutes (run tests 10x with `--seed 0`).

### Risk 4: Telemetry handler interference with existing tests

- **Risk:** Attaching telemetry handlers in Test 7 could interfere with other tests if not properly cleaned up, or existing telemetry handlers could interfere with our assertions.
- **Impact:** Test pollution -- other tests fail or our telemetry test gets spurious events.
- **Mitigation:** Use `setup` + `on_exit` to attach/detach telemetry handlers. Use a unique handler ID per test. Filter events by task_id to avoid counting events from other concurrent tests.
- **Validation time:** 2 minutes.

### Risk 5: Provider.External.start failure path may not be testable without stopping PendingTasks

- **Risk:** `Provider.External.start/1` checks `process_alive?(registry)` but does NOT check if PendingTasks is alive. The failure may only surface later during `PendingTasks.register_task`, which raises, and the error path through `ExternalAgent.dispatch_via_provider` -> `with {:ok, handle} <- ProviderExternal.start(...)` may not catch a later raise.
- **Impact:** Test 4 may need to target a different failure point than originally planned, or the error propagation path may be different than expected.
- **Mitigation:** Read `Provider.External.start/1` carefully (done -- line 77 checks registry only). For Test 4, stop the Gateway.Registry (not PendingTasks) so `Provider.External.start` returns `{:error, :registry_not_available}`. This is a cleaner test target. If we also want to test PendingTasks failure, that's a separate scenario where `PendingTasks.register_task` raises -- covered by ensuring `dispatch_via_provider` handles exceptions from Provider.External.run.
- **Validation time:** 10 minutes.

---

# Recommended API surface

No new public API. All changes are:

1. **Bug fixes** (if needed) to existing private functions:
   - `Executor.run_via_external_agent/3` -- add `try/catch :exit` if Test 2 confirms stale-pid crash
   - `ExternalSupervisor.start_agent/1` -- add `try/catch :exit` if Test 3 confirms supervisor-down crash
   - `Executor.ensure_external_agent/1` -- potentially add `:noproc` handling

2. **New test functions** in `executor_external_test.exs`:
   - 7 adversarial test cases (described in Tests section above)
   - Helper functions for concurrent test setup

---

# Folder structure

```
test/cortex/orchestration/runner/
  executor_external_test.exs      # MODIFY: add 7 adversarial edge-case tests

lib/cortex/orchestration/runner/
  executor.ex                     # MODIFY: fix bugs found (try/catch for :exit signals)

lib/cortex/agent/
  external_supervisor.ex          # MODIFY: fix bugs found (noproc handling)
```

No new files created. All changes are additions to existing files.

---

# Step-by-step task plan in small commits

N/A -- see "Tighten the plan" section below for the authoritative task list.

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Concurrent ensure_external_agent race + supervisor-down safety

- **Outcome:** Test that two concurrent `start_agent` calls for the same team_name both succeed via `:already_started` handling. Test that `ensure_external_agent` returns a clean error when ExternalSupervisor is not running. Fix any bugs found (likely: add try/catch in `start_agent` or `ensure_external_agent` for `:noproc`).
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` -- add Tests 1 and 3
  - `lib/cortex/agent/external_supervisor.ex` -- fix if `:noproc` not handled
  - `lib/cortex/orchestration/runner/executor.ex` -- fix if `:noproc` not handled
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `test(executor): adversarial tests for ensure_external_agent race + supervisor-down`

### Task 2: Stale ExternalAgent pid + Provider.External.start failure

- **Outcome:** Test that calling ExternalAgent.run on a dead process returns `{:error, _}` cleanly. Test that Provider.External.start failure inside ExternalAgent.run propagates to the executor. Fix: add try/catch :exit in `run_via_external_agent` if needed.
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` -- add Tests 2 and 4
  - `lib/cortex/orchestration/runner/executor.ex` -- add try/catch if stale-pid crash confirmed
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `test(executor): adversarial tests for stale pid + provider start failure`

### Task 3: Task.await_many timeout isolation + cross-run state leakage

- **Outcome:** Test that killing a Task mid-GenServer.call leaves ExternalAgent healthy and reusable. Test that sequential runs with same team_name don't leak state. No fix expected (GenServer handles caller death gracefully by design), but validates the invariant.
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` -- add Tests 5 and 6
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `test(executor): adversarial tests for timeout isolation + cross-run state`

### Task 4: Telemetry verification

- **Outcome:** Test that `emit_gateway_task_dispatched` and `emit_gateway_task_completed` telemetry events fire during a successful external dispatch with correct metadata.
- **Files to create/modify:**
  - `test/cortex/orchestration/runner/executor_external_test.exs` -- add Test 7
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/orchestration/runner/executor_external_test.exs --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `test(executor): verify telemetry events in external dispatch path`

### Task 5: Full CI compliance check

- **Outcome:** All tests pass (1367+ existing + 7 new), no warnings, no format issues, no credo violations.
- **Files to create/modify:** None (fix any issues found)
- **Exact verification command(s):**
  ```bash
  mix format
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  ```
- **Suggested commit message:** `chore: fix lint/format issues from executor integration QE`

---

# Benchmark plan + what "success" looks like

N/A -- This is a correctness/QE effort, not a performance effort. There is no critical performance path being modified.

**Success criteria:**
1. 7 adversarial tests all pass.
2. Bugs found are fixed with minimal, surgical changes (expect 2-3 small try/catch additions).
3. Full test suite (1367+ tests) passes with zero regressions.
4. `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict` all clean.

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Executor Integration QE

### Coding Style
- When wrapping GenServer.call or DynamicSupervisor.start_child calls that may raise on dead processes, use `try/catch :exit, _ ->` rather than `Process.alive?` checks (which have a TOCTOU race).
- Adversarial tests should use real processes (not mocks) to catch actual race conditions and exit signal propagation.

### Dev Commands
```bash
mix test test/cortex/orchestration/runner/executor_external_test.exs --trace  # all executor-external tests
mix test test/cortex/orchestration/runner/executor_external_test.exs --only adversarial  # QE edge cases only
```

### Before You Commit
- Run `mix test` (full suite) -- executor changes can have subtle effects on the CLI path
- Verify no `Process.sleep` calls without justification in test code (prefer `assert_receive` with timeout)

### Guardrails
- `run_via_external_agent/3` must catch `:exit` signals from `ExternalAgent.run` -- a dead GenServer raises, not returns
- `ensure_external_agent/1` must handle `:noproc` from a missing ExternalSupervisor
- Tests that kill processes must use `Process.flag(:trap_exit, true)` or `Task.async` isolation to prevent test process crashes

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture Explanation
- The executor -> ExternalAgent path has several failure boundaries: supervisor availability, agent process liveness, Provider.External initialization, and sidecar responsiveness
- Each boundary must produce a clean `{:error, reason}` rather than an exit signal that escapes the Task.async boundary

### Key Engineering Decisions + Tradeoffs
- try/catch :exit for stale-pid safety rather than Process.alive? checks (avoids TOCTOU race)
- Test at integration level with real processes rather than unit-level with mocks (catches real race conditions but is slower)
- Kill simulation via Process.exit rather than real Task.await_many timeout (deterministic, no flaky timing)

### Limits of MVP + Next Steps
- No retry logic: if ExternalAgent crashes, the tier fails. Future work could add retry-with-backoff in `run_via_external_agent`.
- No circuit breaker: repeated failures to the same sidecar are not throttled. Future work could add a health check before dispatch.
- Concurrent dispatch to same ExternalAgent is not tested (current design is one-task-at-a-time per GenServer).

### How to Run Locally + How to Validate
- `mix test test/cortex/orchestration/runner/executor_external_test.exs --trace` to run all edge-case tests
- Tests use real Gateway.Registry, PendingTasks, and ExternalSupervisor processes -- no Docker or external services needed

---

## READY FOR APPROVAL
