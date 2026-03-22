# GenServer Edge Case QE Plan

## You are in PLAN MODE.

### Project
I want to do a **Phase 3.5 QE — GenServer Edge Case Hardening**.

**Goal:** Harden the ExternalAgent GenServer through adversarial testing — find bugs, race conditions, and edge cases in the GenServer itself and its PubSub/state interactions, then fix them.

### Role + Scope (fill in)
- **Role:** GenServer Edge Case Engineer
- **Scope:** Adversarial testing of the ExternalAgent GenServer lifecycle, state machine transitions, PubSub event ordering, and caller experience under failure. I own edge-case tests in `test/cortex/agent/external_agent_test.exs` and bug fixes in `lib/cortex/agent/external_agent.ex`. I do NOT own the executor integration path, ExternalSupervisor internals, Provider.External dispatch logic, or Gateway.Registry.
- **File you will write:** `docs/compute-spawning/phase-3.5-external-agent-qe/plans/genserver-edge-cases.md`
- **No-touch zones:** do not edit executor.ex, external_supervisor.ex, provider/external.ex, gateway/registry.ex, application.ex, or any YAML config.

---

## Functional Requirements
- **FR1:** Sidecar disconnect mid-task: When `:agent_unregistered` PubSub arrives while `Provider.External.run` is blocking inside `handle_call`, the state update must be queued and applied after `handle_call` returns. Verify the GenServer ends up `:unhealthy` and subsequent `run/3` calls are rejected.
- **FR2:** GenServer crash during `run/3` dispatch: If `dispatch_via_provider/3` raises or the GenServer process dies mid-call, the caller must receive a clean exit signal (not hang forever). Verify the caller gets `{:EXIT, ...}` or `{:error, _}`, not a timeout.
- **FR3:** Rapid disconnect/reconnect: `:agent_unregistered` then `:agent_registered` in quick succession must leave the GenServer in a consistent state — healthy with the correct new `agent_id`.
- **FR4:** Stale PubSub reconnect: `:agent_registered` with matching name but the agent is already gone from the registry by the time we query. GenServer must remain in its current state (not crash, not corrupt state).
- **FR5:** Multiple queued `run/3` calls: When multiple callers call `run/3`, the second blocks until the first completes. Both must receive correct, distinct results.
- **FR6:** `stop/1` called while `run/3` is in progress: The blocked `run/3` caller must receive a clean error (`:normal` exit from GenServer.stop), not hang.
- **FR7:** `start_link` when Gateway.Registry is slow or overloaded: The `init/1` callback must handle `:exit` from `GatewayRegistry.list/1` and return `{:stop, :registry_not_available}`.
- **Tests required:** All scenarios above as unit tests in `external_agent_test.exs`. Use `async: false` (PubSub is shared state).

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+ / OTP 26+
- Local dev: `mix test test/cortex/agent/external_agent_test.exs`
- Observability: N/A for tests
- Safety: All edge cases must produce clean error tuples or exits — no hangs, no corrupted state, no unhandled crashes
- Documentation: `@moduledoc`, `@doc`, `@spec` on any new public functions; inline comments on non-obvious fixes
- Performance: N/A

---

## Assumptions / System Model
- **Deployment environment:** Single BEAM node, test environment with `start_supervised!` for process lifecycle.
- **Failure modes:**
  - GenServer mailbox ordering: OTP guarantees FIFO for messages from a single sender, but PubSub broadcasts from different senders can interleave with `GenServer.call` messages in any order.
  - `handle_call({:run, ...})` blocks the GenServer mailbox: While `dispatch_via_provider/3` is executing synchronously inside `handle_call`, all PubSub `handle_info` messages queue behind it. The state update from `:agent_unregistered` will NOT be applied until after the `handle_call` returns. This is inherent to GenServer semantics.
  - `GenServer.stop/1` sends an exit signal: If `run/3` is in progress via `GenServer.call`, the caller receives `{:EXIT, pid, :normal}` (or catches it as `** (exit) normal`). This is OTP behavior, not a bug — but the test should verify it.
- **Delivery guarantees:** PubSub is at-most-once. A missed event means stale state until the next event.
- **Multi-tenancy:** None.

---

## Data Model (as relevant to your role)
N/A — not in scope for this role. The GenServer state model is defined by the ExternalAgent Engineer. This QE role probes the existing state machine for correctness under adversarial conditions.

---

## APIs (as relevant to your role)
N/A — no new public API surface. This role adds tests and potentially patches to private functions in `external_agent.ex`.

---

## Architecture / Component Boundaries (as relevant)

### Key Insight: GenServer Mailbox Serialization

The ExternalAgent `handle_call({:run, ...})` calls `dispatch_via_provider/3` synchronously. This means the GenServer is blocked for the entire duration of the Provider.External round trip (potentially minutes). During this time:

1. PubSub `:agent_unregistered` events queue in the mailbox as `handle_info` messages.
2. Additional `GenServer.call({:run, ...})` from other callers queue in the mailbox.
3. `GenServer.stop/1` sends an exit signal which will be processed after `handle_call` returns.

This is correct OTP behavior — the state is consistent because only one callback runs at a time. But it means:
- A disconnect event during a run won't prevent the current run from completing (or timing out). The state transitions to `:unhealthy` only after the run returns.
- The second `run/3` caller may execute against an agent that disconnected during the first caller's run. The second call will see the `:unhealthy` state only if the PubSub event is processed between the two `handle_call` invocations.

### Components I Touch
- **ExternalAgent GenServer** (`lib/cortex/agent/external_agent.ex`): Bug fixes for edge cases found during testing.
- **ExternalAgent Tests** (`test/cortex/agent/external_agent_test.exs`): New adversarial test cases.

### Components I Consume (read-only)
- **Gateway.Registry** — for test setup (registering mock agents)
- **Provider.External.PendingTasks** — for test setup (simulating sidecar responses)
- **Cortex.Events** — for broadcasting PubSub events in tests

---

## Correctness Invariants (must be explicit)

1. **Mailbox ordering preserves state consistency:** PubSub events queued during a blocking `handle_call` are applied after the call returns. The state after processing must be identical to applying events in arrival order.
2. **Unhealthy state persists until explicit reconnect:** Once `:agent_unregistered` transitions state to `:unhealthy`, only an `:agent_registered` event with matching name (and successful registry lookup) can restore `:healthy`.
3. **Reconnect updates agent_id atomically:** After `:agent_registered`, `agent_id`, `agent_info`, and `status` must all reflect the new sidecar. There is no intermediate state where `agent_id` is new but `status` is still `:unhealthy`.
4. **Stale reconnect is a no-op:** If `:agent_registered` arrives but `GatewayRegistry.get/2` returns `{:error, :not_found}`, the state must not change. Specifically, `status` must not flip to `:healthy`.
5. **Caller gets clean error on GenServer death:** If the GenServer process terminates (via `stop/1` or crash) while a `run/3` caller is blocked, the caller receives an exit signal, not a hang.
6. **Sequential callers get correct results:** Multiple `run/3` calls processed sequentially by the GenServer each receive their own result, not a stale or mixed result.
7. **Provider.External errors don't crash the GenServer:** If `ProviderExternal.start/1` or `ProviderExternal.run/3` raises, the GenServer must survive (the `try` in `dispatch_via_provider/3` only covers `run`, not `start`).

---

## Tests

### Edge Case Tests (in `test/cortex/agent/external_agent_test.exs`)

**1. Sidecar disconnect mid-task (PubSub queued behind handle_call)**
- Start ExternalAgent with a `push_fn` that sleeps 200ms before resolving.
- Immediately after calling `ExternalAgent.run/3` (in a Task), broadcast `:agent_unregistered`.
- Assert `run/3` returns `{:ok, _}` (the task was already in-flight; Provider.External completes it).
- Assert `get_state/1` shows `:unhealthy` after run completes (PubSub event processed).
- Assert subsequent `run/3` returns `{:error, :agent_unhealthy}`.

**2. GenServer crash during dispatch — caller gets clean exit**
- Start ExternalAgent with a `push_fn` that calls `Process.exit(self(), :kill)` (kills the GenServer process from within handle_call).
- Call `ExternalAgent.run/3` and catch the exit.
- Assert the caller receives `{:EXIT, _, :killed}` (not a hang or timeout).

**3. Rapid disconnect/reconnect — final state is healthy with new agent_id**
- Start ExternalAgent.
- Broadcast `:agent_unregistered` for old agent_id.
- Immediately broadcast `:agent_registered` with matching name and new agent_id (register new agent in Gateway.Registry first).
- Wait for PubSub delivery.
- Assert `get_state/1` shows `:healthy` with the new `agent_id`.

**4. Reconnect with stale agent_id (registry returns :not_found)**
- Start ExternalAgent, broadcast `:agent_unregistered`.
- Broadcast `:agent_registered` with matching name but an agent_id that is NOT in Gateway.Registry (agent was already gone).
- Assert state remains `:unhealthy` (the reconnect handler's `GatewayRegistry.get` returns `:not_found`, so state is unchanged).
- Assert `agent_id` is still the original (not updated to the stale one).

**5. Multiple queued run/3 calls — both get correct results**
- Start ExternalAgent with a `push_fn` that resolves after 100ms.
- Spawn two Tasks: both call `ExternalAgent.run/3` with different prompts.
- Assert both return `{:ok, _}` (second waits for first to complete).
- Assert both results have the correct team name.
- Verify ordering: first call completes before second (check timestamps or sequential push_fn calls).

**6. stop/1 while run/3 is in progress — caller gets exit**
- Start ExternalAgent with a `push_fn` that never resolves (simulates a hung sidecar).
- In a Task, call `ExternalAgent.run/3`.
- After a short delay, call `ExternalAgent.stop/1`.
- Assert the `run/3` Task exits with `{:EXIT, _, :normal}` or catches `** (exit) normal`.
- Assert the GenServer is no longer alive.

**7. Provider.External.start returns error inside dispatch_via_provider**
- Start ExternalAgent, then manually unregister the sidecar from Gateway.Registry (kill the transport pid) WITHOUT broadcasting PubSub (to avoid the unhealthy transition).
- Call `run/3` — `dispatch_via_provider` calls `ProviderExternal.start/1` which queries the registry for the agent and fails.
- Assert `run/3` returns `{:error, _}` (not a crash).
- Assert the GenServer is still alive (the error didn't crash it).

### Commands

```bash
mix test test/cortex/agent/external_agent_test.exs --trace
mix test test/cortex/agent/external_agent_test.exs
mix compile --warnings-as-errors
mix test
```

---

## Benchmarks + "Success"
N/A — this is a QE/hardening role. Success is measured by:
- All 7 edge case tests pass
- Zero bugs found that aren't covered by a test
- Any bugs found are fixed with minimal, targeted patches
- All existing 13 ExternalAgent tests + 8 ExternalSupervisor tests + 5 executor-external tests continue to pass
- Full suite (1367+ tests) passes with zero regressions

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Test PubSub-during-handle_call via timing (sleep + Task) vs. direct GenServer state injection

- **Decision:** Use `Task.async` to call `run/3` with a slow `push_fn`, then broadcast PubSub events while the call is in progress. Rely on timing (sleep) to ensure the PubSub event arrives while `handle_call` is blocking.
- **Alternatives considered:**
  - **Direct `:sys.replace_state` injection:** Manually set the GenServer state to simulate mid-call conditions. This avoids timing but doesn't test the actual mailbox queueing behavior.
  - **Custom GenServer wrapper with hooks:** Wrap ExternalAgent in a test harness that pauses execution at specific points. Overly complex for the scenarios being tested.
- **Why:** The actual behavior we're testing is OTP's mailbox serialization. Timing-based tests with generous sleeps (100-200ms) are reliable in practice and test the real execution path. The `push_fn` injection point gives us precise control over how long `handle_call` blocks.
- **Tradeoff acknowledged:** Timing-based tests can be flaky on extremely slow CI machines. Mitigated by using generous sleep durations (200ms+ for a 10ms operation) and not asserting exact timing, only ordering.

### Decision 2: Test stop-during-run via catch/exit vs. Process.monitor

- **Decision:** Use `Task.async` for the `run/3` caller, call `stop/1` from the test process, then `Task.await` and catch the exit.
- **Alternatives considered:**
  - **Process.monitor the Task and assert :DOWN:** More explicit about the failure mode but doesn't verify what the caller actually sees.
  - **Wrap run/3 in try/catch inside the Task and send result back:** More complex but gives exact control over what error the caller observes.
- **Why:** `Task.await` on a Task whose linked GenServer died will raise `{:exit, reason}`. This is the exact experience a real caller (the executor's Task.async) would have. Testing it this way validates the real failure path.
- **Tradeoff acknowledged:** The test must handle the `Task.await` failure gracefully, which adds try/catch boilerplate. But it matches reality.

### Decision 3: Fix Provider.External.start error handling vs. document as known limitation

- **Decision:** If testing reveals that `ProviderExternal.start/1` errors crash the GenServer (because the `try/after` in `dispatch_via_provider` only wraps `run`, not `start`), fix it by wrapping the entire `with` + `try` block in a rescue.
- **Alternatives considered:**
  - **Document as known limitation:** Note that `start` errors propagate as crashes and let the supervisor handle it. Simpler but leaves a sharp edge.
- **Why:** The ExternalAgent uses `restart: :temporary`, so a crash means the agent is gone permanently. The executor's `ensure_external_agent/1` would need to start a new one. It's cleaner to catch the error inside the GenServer and return `{:error, reason}` to the caller. This keeps the GenServer alive for potential retry or health monitoring recovery.
- **Tradeoff acknowledged:** Adding a `rescue` around `ProviderExternal.start` could mask unexpected errors. Mitigated by logging the error at `:warning` level before returning `{:error, reason}`.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Timing-dependent tests are flaky on CI

- **Risk:** Tests that rely on PubSub delivery during a blocking `handle_call` may fail if the test process is delayed or PubSub delivery is unusually slow.
- **Impact:** Intermittent CI failures that erode confidence in the test suite.
- **Mitigation:** Use generous sleep durations (200ms+). Use polling loops with `Process.sleep(10)` + retry for state assertions instead of fixed sleeps. Keep the slow `push_fn` delay long enough (200ms) that there's no race between PubSub delivery and assertion.
- **Validation time:** < 10 minutes (run edge case tests 10 times in a loop).

### Risk 2: PubSub subscription in tests may miss events

- **Risk:** If `Cortex.Events.subscribe()` has a timing window where events broadcast immediately after subscribe are lost, tests may see stale state.
- **Impact:** Tests pass locally but fail intermittently.
- **Mitigation:** The existing tests already use this pattern successfully (e.g., the "agent_unregistered" test at line 197). Follow the same pattern: subscribe happens in `init/1` (synchronous with `start_link`), broadcast happens after `start_link` returns, so the subscription is always in place before events fire.
- **Validation time:** < 5 minutes (review existing test patterns).

### Risk 3: dispatch_via_provider fix introduces regressions

- **Risk:** Adding a `rescue` or modifying the error handling in `dispatch_via_provider/3` could change behavior for the happy path.
- **Impact:** Existing tests fail.
- **Mitigation:** Any fix will be minimal and targeted — e.g., wrapping `ProviderExternal.start` in a rescue that only catches specific errors. Run the full existing test suite before and after the fix. The fix will NOT change the happy path code.
- **Validation time:** < 5 minutes (run existing ExternalAgent tests).

### Risk 4: GenServer mailbox behavior differs across OTP versions

- **Risk:** OTP mailbox ordering guarantees might have subtleties across versions that affect test assumptions.
- **Impact:** Tests that rely on specific message ordering could fail on different OTP versions.
- **Mitigation:** The tests don't rely on cross-sender ordering (which is undefined). They rely on: (a) `handle_call` completing before the next callback runs (GenServer contract), and (b) PubSub events eventually being delivered (Phoenix.PubSub contract). Both are stable across OTP 25+.
- **Validation time:** < 5 minutes (check OTP version in mix.exs).

### Risk 5: Test isolation — PubSub events leak between tests

- **Risk:** Since tests use `async: false` and share `Cortex.PubSub`, events from one test could leak into another.
- **Impact:** Flaky test failures due to unexpected PubSub messages.
- **Mitigation:** Each test uses unique agent names and agent_ids (via `System.unique_integer`). PubSub handlers pattern-match on `agent_id` or `name`, so events from other tests are caught by the catch-all `handle_info` and ignored. The existing tests already follow this pattern.
- **Validation time:** < 5 minutes (review existing test isolation patterns).

---

## Recommended API surface

No new public API. This role adds tests and potentially patches private functions.

### Potential Patches (if bugs found)

1. **`dispatch_via_provider/3`** — If `ProviderExternal.start/1` errors crash the GenServer, add error handling:
   ```elixir
   # Current (line 260-266):
   with {:ok, handle} <- ProviderExternal.start(provider_config) do
     try do
       ProviderExternal.run(handle, prompt, team_name: team_name, timeout_ms: timeout_ms)
     after
       ProviderExternal.stop(handle)
     end
   end

   # Potential fix — wrap in rescue to catch start/run errors:
   try do
     with {:ok, handle} <- ProviderExternal.start(provider_config) do
       try do
         ProviderExternal.run(handle, prompt, team_name: team_name, timeout_ms: timeout_ms)
       after
         ProviderExternal.stop(handle)
       end
     end
   rescue
     e -> {:error, {:dispatch_failed, Exception.message(e)}}
   end
   ```

2. **`handle_call({:run, ...})`** — If testing reveals the GenServer doesn't handle `:EXIT` signals from linked Provider processes cleanly, add `Process.flag(:trap_exit, true)` in `init/1` and a `handle_info({:EXIT, _, _})` clause.

---

## Folder structure

```
lib/cortex/agent/
  external_agent.ex              # MODIFY: bug fixes for edge cases found
test/cortex/agent/
  external_agent_test.exs        # MODIFY: add 7 edge case tests
```

No new files created.

---

## Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Mid-task disconnect + post-run state verification

- **Outcome:** Test proves that PubSub `:agent_unregistered` during a blocking `run/3` is queued behind `handle_call`, state transitions to `:unhealthy` after run completes, and subsequent `run/3` is rejected.
- **Files to create/modify:**
  - `test/cortex/agent/external_agent_test.exs` — add "sidecar disconnect mid-task" test in a new `describe "edge cases"` block
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs --trace
  ```
- **Suggested commit message:** `test(agent): verify PubSub queuing during blocking ExternalAgent.run`

### Task 2: Rapid disconnect/reconnect + stale reconnect

- **Outcome:** Two tests: (a) rapid `:agent_unregistered` then `:agent_registered` leaves GenServer healthy with new agent_id; (b) `:agent_registered` where registry returns `:not_found` leaves state unchanged.
- **Files to create/modify:**
  - `test/cortex/agent/external_agent_test.exs` — add "rapid disconnect/reconnect" and "stale reconnect" tests
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs --trace
  ```
- **Suggested commit message:** `test(agent): verify ExternalAgent reconnect edge cases (rapid + stale)`

### Task 3: Multiple queued run/3 calls + stop during run

- **Outcome:** Two tests: (a) two concurrent `run/3` callers both get correct sequential results; (b) `stop/1` during `run/3` gives the blocked caller a clean exit, not a hang.
- **Files to create/modify:**
  - `test/cortex/agent/external_agent_test.exs` — add "queued run calls" and "stop during run" tests
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs --trace
  ```
- **Suggested commit message:** `test(agent): verify ExternalAgent concurrent run + stop-during-run`

### Task 4: Provider.External.start failure + dispatch_via_provider hardening

- **Outcome:** Test proves that a Provider.External.start error inside `dispatch_via_provider/3` returns `{:error, _}` to the caller without crashing the GenServer. If the current code crashes, apply a minimal fix (rescue in `dispatch_via_provider`).
- **Files to create/modify:**
  - `test/cortex/agent/external_agent_test.exs` — add "provider start failure" test
  - `lib/cortex/agent/external_agent.ex` — fix `dispatch_via_provider/3` if it crashes on start error (add rescue)
- **Exact verification command(s):**
  ```bash
  mix test test/cortex/agent/external_agent_test.exs --trace
  mix compile --warnings-as-errors
  ```
- **Suggested commit message:** `fix(agent): handle Provider.External.start errors in dispatch_via_provider`

### Task 5: Full suite verification + format/lint compliance

- **Outcome:** All edge case tests pass. All 13 existing ExternalAgent tests pass. All 8 ExternalSupervisor tests pass. All 5 executor-external tests pass. Full suite (1367+) passes. Format, compile warnings, and credo all clean.
- **Files to create/modify:** None (fix any issues found)
- **Exact verification command(s):**
  ```bash
  mix format
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  ```
- **Suggested commit message:** `chore: verify full suite after ExternalAgent edge case hardening`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From GenServer Edge Case Engineer

**Coding style rules:**
- Edge case tests go in a `describe "edge cases"` block within the relevant test file, not in a separate file.
- Use `Task.async` + `Task.await` (or `Task.yield`) to test concurrent GenServer interactions. Never rely on `Process.sleep` alone for synchronization — always assert on observable state changes.
- When testing PubSub event ordering, use generous timeouts (200ms+) and polling loops, not fixed sleeps.

**Dev commands:**
```bash
mix test test/cortex/agent/external_agent_test.exs --trace  # ExternalAgent tests (includes edge cases)
```

**Before you commit checklist:**
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test` (all pass)
5. No `IO.inspect` or `dbg()` left in code

**Guardrails:**
- Do not add `Process.flag(:trap_exit, true)` to ExternalAgent unless a specific test proves it's needed. Trapping exits changes GenServer shutdown semantics and can mask bugs.
- Do not wrap `run/3` in a `try/rescue` at the `handle_call` level — let OTP propagate exits naturally to callers. The fix belongs in `dispatch_via_provider/3` where the external call happens.
- GenServer.call timeout must always exceed Provider.External's internal timeout to prevent GenServer exit crashes (this is already enforced by `timeout_or_infinity/1`).

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture Explanation
- ExternalAgent `handle_call({:run, ...})` blocks the GenServer for the entire Provider.External round trip. All PubSub events queue behind it.
- This is correct OTP behavior: the GenServer processes one callback at a time, so state is always consistent.
- A sidecar disconnect during a run doesn't abort the current task — it queues the state transition for after the run returns.

### Key Engineering Decisions + Tradeoffs
- Timing-based tests with generous sleeps are preferred over mocking GenServer internals, because we're testing real OTP mailbox behavior.
- `dispatch_via_provider` wraps the full Provider.External lifecycle in error handling to prevent GenServer crashes from transient provider failures.

### Limits of MVP + Next Steps
- No concurrent dispatch per agent: only one `run/3` at a time. Additional calls queue in the GenServer mailbox.
- PubSub event loss (e.g., missed `:agent_unregistered`) would leave stale state. A periodic health check (polling Gateway.Registry) could mitigate this in a future phase.
- No test for partial Provider.External responses (e.g., `run` returns but `stop` raises). Could be added if Provider.External semantics change.

### How to Run Locally + How to Validate
- `mix test test/cortex/agent/external_agent_test.exs --trace` to see all edge case tests
- Run 10x in a loop to verify no flakiness: `for i in $(seq 1 10); do mix test test/cortex/agent/external_agent_test.exs --seed 0 || break; done`

---

## READY FOR APPROVAL
