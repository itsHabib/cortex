# Phase 2: OTP Foundation QE — Summary

> 175 tests, 0 failures (9 new QE tests + 166 from Phase 1).

## What This Phase Did

Phase 2 is the "quality engineering" pass — stress-testing and fault-injecting everything Phase 1 built. Phase 1 already had solid test coverage (166 tests), so Phase 2 focused on the gaps: **what happens when things go wrong?**

## Bug Found & Fixed

**Restart strategy mismatch:** The Agent Server was using the GenServer default restart strategy (`:permanent` — always restart on crash), but the design says `:temporary` (never auto-restart — let the orchestrator decide). This matters because:
- With `:permanent`, a crashing agent would restart automatically in a loop, potentially hitting the supervisor's max restart limit and taking down healthy agents too
- With `:temporary`, a crashed agent just dies, the supervisor stays healthy, and the DAG engine (Phase 3) decides what to do about it

Fixed with one line: `use GenServer, restart: :temporary`.

## New Tests Added

### 1. Fault Injection — Agent Crash Recovery
Kills an agent process violently (`Process.exit(pid, :kill)`) and verifies:
- The Registry automatically cleans up the dead entry
- The DynamicSupervisor stays healthy
- New agents can still be started after the crash

**Why it matters:** In production, agent processes might crash from LLM timeouts, tool failures, or OOM. The system must handle this gracefully — not cascade the failure.

### 2. Fault Injection — Concurrent Crashes
Starts 5 agents, kills 3 simultaneously, then verifies:
- The 2 survivors are still running and reachable
- The 3 killed agents are fully cleaned up

**Why it matters:** In a DAG run, multiple agents might fail at once (e.g., API rate limit hits all of them). The system needs to handle bulk failures.

### 3. Stress Test — 20 Concurrent Agents
Starts 20 agents in rapid succession, verifies all 20 are registered and findable, then stops all 20 and verifies the Registry is clean.

**Why it matters:** Proves the supervision tree can handle concurrent agent creation without race conditions in Registry registration.

### 4. Event Ordering Under Load
Starts 5 agents rapidly and verifies exactly 5 `:agent_started` events are received, each with the correct agent ID.

**Why it matters:** The dashboard and orchestrator will rely on events to track what's happening. Missing or duplicate events would cause confusion.

### 5. Cross-Component Lifecycle
Full end-to-end test: start agent → subscribe to events → run a tool via the Executor → update agent status → verify events fired → stop agent → verify cleanup.

**Why it matters:** This is the closest thing to a real workflow. It proves all the Phase 1 components actually work together, not just in isolation.

### 6. Agent State Consistency Under Concurrency
5 processes simultaneously update different metadata keys on the same agent. Verifies no updates are lost.

**Why it matters:** GenServers serialize access through their mailbox, so this _should_ work. This test proves it does. In production, the orchestrator and tools might both update an agent's metadata concurrently.

## Key Insight: `terminate/2` Behavior

The QE phase revealed that `DynamicSupervisor.terminate_child/2` does NOT guarantee the GenServer's `terminate/2` callback runs (because the GenServer doesn't trap exits). This means the `:agent_stopped` event only fires when you use `Server.stop/1` (graceful shutdown), not when the supervisor force-kills a child.

This is fine for now — the orchestrator should use `Server.stop/1` for planned shutdowns. For unexpected crashes, the Registry auto-cleanup is sufficient.
