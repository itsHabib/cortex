# Runs Consolidation Plan

## You are in PLAN MODE.

### Project
I want to do a **UI restructure of the Cortex web layer**.

**Goal:** Consolidate RunList + RunDetail + RunCompare + TeamDetail + Jobs into one coherent runs flow where users monitor, inspect, and act on multi-agent runs regardless of coordination mode.

### Role + Scope
- **Role:** Runs Consolidation Designer
- **Scope:** Own the `/runs` route tree -- list, detail, compare, team drill-down, and per-run jobs. Do NOT own the Agents page, Workflows page, Overview page, sidebar/layout shell, or shared component library.
- **File you will write:** `/docs/ui-restructure/plans/runs-consolidation.md`
- **No-touch zones:** Do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1 — Unified Run List:** A single `/runs` page showing all runs with sortable columns for name, status, mode (DAG/Mesh/Gossip icon+label), teams/agents/nodes count, token usage, duration, and started-at. Mode indicator replaces the current plain text badge with a colored icon. Status filter dropdown stays. Delete action stays.
- **FR2 — Inline Compare Mode:** Eliminate `/runs/compare` as a separate page. Add a "Compare" toggle/mode on the run list that lets users select 2+ completed runs and view a side-by-side token/cost comparison table in a slide-down panel below the list. This replaces the standalone RunCompareLive.
- **FR3 — Mode-Adaptive Run Detail:** `/runs/:id` restructures its 8 tabs into universal tabs (Overview, Activity, Logs, Settings) plus mode-specific tabs that appear conditionally:
  - DAG runs: show "Graph" tab with tier visualization + dependency edges
  - Mesh runs: show "Membership" tab with SWIM states, heartbeat config, message flow
  - Gossip runs: show "Knowledge" tab with round progress, topology, convergence entries
  - All modes: "Diagnostics" tab (merges current Diagnostics + Debug reports), "Summaries" tab, "Jobs" tab (per-run internal jobs only)
- **FR4 — Team Detail as Slide-Over Panel:** Replace `/runs/:id/teams/:name` as a separate page with a slide-over panel anchored to the right side of RunDetailLive. Clicking a team/agent/node card on the Overview tab opens the panel without a navigation event. Panel contains: result, log viewer, diagnostics, resume/restart actions. Back button or click-outside dismisses.
- **FR5 — Kill Standalone Jobs Page:** Remove `/jobs` as a top-level nav item. Per-run jobs are already shown in RunDetailLive's Jobs tab. The global jobs view becomes unnecessary once every job is reachable from its parent run.
- **FR6 — Run Actions:** Expose stop, resume, retry, and delete actions consistently. Stop/resume are on running runs (already exist). Retry re-launches a completed/failed run with the same config. Delete stays on the list.
- **FR7 — Run Grouping (future-ready, not MVP):** The run list data model already has `name` which users set. For MVP, no explicit grouping UI -- users can sort/filter by name. A future iteration could add a `project` or `group` field.

- **Tests required:** LiveView tests for tab rendering per mode, compare panel toggle, slide-over open/close, run action event handlers. No backend changes needed.
- **Metrics required:** N/A -- no new backend metrics. Existing telemetry covers run lifecycle.

## Non-Functional Requirements

- Language/runtime: Elixir/Phoenix LiveView, Tailwind CSS (dark mode)
- Local dev: `mix phx.server` (port 4000)
- Observability: Existing `/metrics` endpoint unchanged
- Safety: No backend changes. All restructuring is web layer only. PubSub event subscriptions unchanged.
- Documentation: Update CLAUDE.md with new route map. Add EXPLAIN.md bullets.
- Performance: RunDetailLive is 4,454 LOC -- this plan restructures it into smaller modules but does not change any data fetching patterns. The slide-over panel avoids a full page reload for team drill-down, which is a performance improvement.

---

## Assumptions / System Model

- Deployment environment: Local `mix phx.server`; no containerization needed for web layer
- Failure modes: Not applicable -- web layer only, backend is stable
- Delivery guarantees: N/A
- Multi-tenancy: N/A

---

## Data Model (as relevant to your role)

No new Ecto schemas or migrations. The existing data model is sufficient:

- **Run** — id, name, status, mode, config_yaml, workspace_path, team_count, total_input_tokens, total_output_tokens, total_cache_read_tokens, total_cache_creation_tokens, total_duration_ms, gossip_rounds_total, gossip_rounds_completed, started_at, completed_at, inserted_at
- **TeamRun** — id, run_id, team_name, role, status, tier, internal, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, duration_ms, result_summary, session_id, log_path, started_at, completed_at

The `mode` field on Run (`"workflow"` | `"mesh"` | `"gossip"`) drives conditional tab rendering. No schema changes needed.

---

## APIs (as relevant to your role)

No new API endpoints. The existing JSON API (`/api/runs`, `/api/runs/:id`) is unchanged. All changes are LiveView routes and event handlers.

### Route Changes

**Remove:**
- `live("/runs/compare", RunCompareLive, :index)` -- folded into RunListLive
- `live("/runs/:id/teams/:name", TeamDetailLive, :show)` -- becomes slide-over in RunDetailLive
- `live("/jobs", JobsLive, :index)` -- per-run jobs already in RunDetailLive

**Keep:**
- `live("/runs", RunListLive, :index)` -- enhanced with compare mode
- `live("/runs/:id", RunDetailLive, :show)` -- restructured tabs + slide-over

### LiveView Event Handlers (RunListLive additions)

| Event | Params | Behavior |
|-------|--------|----------|
| `toggle_compare` | `%{}` | Toggle compare mode on/off; clears selections |
| `toggle_select_run` | `%{"id" => id}` | Add/remove run from compare selection |

### LiveView Event Handlers (RunDetailLive additions)

| Event | Params | Behavior |
|-------|--------|----------|
| `open_team_panel` | `%{"team" => name}` | Open slide-over for team, load logs/diagnostics |
| `close_team_panel` | `%{}` | Close slide-over panel |
| `retry_run` | `%{}` | Re-launch run with same config_yaml |

---

## Architecture / Component Boundaries

### Current State (problems)

1. **RunDetailLive is 4,454 LOC** -- a god-module handling 8 tabs, 3 coordination modes, coordinator management, messaging, diagnostics, summaries, jobs, and settings. Unmaintainable.
2. **RunCompareLive is a separate page** for a feature that is naturally a list-level operation (select runs, compare).
3. **TeamDetailLive is a separate page** that forces a full navigation for what should be a quick drill-down.
4. **JobsLive duplicates** what RunDetailLive's Jobs tab already shows, but globally.
5. **Mode-specific content is interleaved** with `if non_dag?(@run)` / `if gossip?(@run)` / `if mesh?(@run)` conditionally scattered through the overview rendering.

### Proposed State

```
lib/cortex_web/live/
  run_list_live.ex          -- Enhanced with inline compare panel
  run_detail_live.ex        -- Slimmed coordinator: delegates to tab components
  run_detail/
    overview_tab.ex         -- Overview: status cards, participant cards, activity feed
    activity_tab.ex         -- Full activity feed with team filter
    messages_tab.ex         -- Message viewer + sender
    logs_tab.ex             -- Log viewer with team selector
    diagnostics_tab.ex      -- Merged diagnostics + debug reports
    summaries_tab.ex        -- Agent + DB summaries
    jobs_tab.ex             -- Per-run internal jobs
    settings_tab.ex         -- Run config, metadata, YAML viewer
    graph_tab.ex            -- DAG-only: tier visualization (extracts from overview)
    membership_tab.ex       -- Mesh-only: SWIM states, heartbeat config
    knowledge_tab.ex        -- Gossip-only: round progress, topology, knowledge entries
  components/
    team_slide_over.ex      -- Slide-over panel for team drill-down
    compare_panel.ex        -- Inline comparison table for run list
    run_mode_icon.ex        -- DAG/Mesh/Gossip icon component
```

### How it works

1. **RunDetailLive stays as the parent LiveView.** It owns the socket, PubSub subscriptions, and assigns. Tab components are function components or `live_component` modules that receive assigns and render their section.
2. **Tab components are stateless function components** (`use Phoenix.Component`) that receive all needed assigns from the parent. They do NOT subscribe to PubSub independently. This keeps state management centralized while breaking up the render into maintainable pieces.
3. **Slide-over panel** is a component that conditionally renders when `@team_panel_open` is true. It receives team_run, log_lines, and diagnostics as assigns from RunDetailLive. Opening/closing is handled by RunDetailLive events.
4. **Compare panel** is a component within RunListLive that renders when `@compare_mode` is true. Selected run IDs are tracked in assigns. The comparison table reuses the same token calculation logic from RunCompareLive.
5. **Mode-specific tabs** are registered in a `visible_tabs/1` function that pattern-matches on `run.mode`:
   - `"workflow"` (DAG): `~w(overview graph activity messages logs diagnostics summaries jobs settings)`
   - `"mesh"`: `~w(overview membership activity messages logs diagnostics summaries jobs settings)`
   - `"gossip"`: `~w(overview knowledge activity messages logs diagnostics summaries jobs settings)`

### Config change propagation
N/A -- no config changes. PubSub subscriptions are unchanged.

### Concurrency model
Unchanged. RunDetailLive process handles PubSub messages sequentially. Tab components are rendered in the same process.

### Backpressure
N/A -- web layer only.

---

## Correctness Invariants (must be explicit)

1. **Mode-specific tabs only appear for their mode.** A DAG run must never show the "Knowledge" tab. A Gossip run must never show the "Graph" tab. Protected by `visible_tabs/1` pattern matching.
2. **Slide-over panel state is scoped to a single team.** Opening a different team replaces the current panel content. Closing clears all panel assigns.
3. **Compare mode selections are cleared on mode exit or page navigation.** No stale selections persist.
4. **All existing RunDetailLive event handlers continue to work.** Tab extraction must not break any `handle_event` or `handle_info` clause. The parent LiveView still receives all events.
5. **Removing TeamDetailLive route does not break internal links.** All `href={"/runs/#{id}/teams/#{name}"}` links in RunDetailLive become `phx-click="open_team_panel"` events.
6. **Removing JobsLive route is safe** because no other page links to `/jobs` except the sidebar (which this restructure removes).
7. **Removing RunCompareLive route is safe** because RunListLive's "Compare Runs" button (`href="/runs/compare"`) becomes a `phx-click="toggle_compare"` event.

---

## Tests

### Unit tests (function components)
- `test/cortex_web/live/run_detail/overview_tab_test.exs` -- renders status cards, team cards, activity feed; mode-conditional content
- `test/cortex_web/live/run_detail/graph_tab_test.exs` -- renders DAG visualization; only for workflow mode
- `test/cortex_web/live/run_detail/membership_tab_test.exs` -- renders SWIM membership; only for mesh mode
- `test/cortex_web/live/run_detail/knowledge_tab_test.exs` -- renders gossip rounds; only for gossip mode

### Integration tests (LiveView)
- `test/cortex_web/live/run_list_live_test.exs` -- existing tests + new: compare mode toggle, run selection, compare panel render
- `test/cortex_web/live/run_detail_live_test.exs` -- existing tests + new: mode-specific tab visibility, slide-over open/close, tab component delegation
- `test/cortex_web/live/run_detail/team_slide_over_test.exs` -- panel renders with team data, close event, log/diagnostics display

### Property/fuzz tests
N/A for UI restructure.

### Failure injection tests
N/A for UI restructure.

### Commands
```bash
mix test test/cortex_web/live/run_list_live_test.exs
mix test test/cortex_web/live/run_detail_live_test.exs
mix test test/cortex_web/live/run_detail/
mix test
```

---

## Benchmarks + "Success"

N/A -- this is a UI restructure. No performance-critical paths are changed.

**Success criteria:**
- All existing tests pass after restructure
- RunDetailLive drops from 4,454 LOC to under 500 LOC (coordinator role only)
- Tab components are each under 300 LOC
- No regressions in PubSub event handling
- `mix compile --warnings-as-errors` passes
- `mix credo --strict` passes

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Function Components vs LiveComponents for tabs

- **Decision:** Use stateless function components (`use Phoenix.Component`) for all tab modules.
- **Alternatives considered:** `Phoenix.LiveComponent` with their own `update/2` and `handle_event/2`.
- **Why:** Tab components do not need independent state or event handling. All state lives in RunDetailLive's assigns, and all events route through RunDetailLive's `handle_event`. Function components are simpler, have zero overhead (no extra process), and are the Phoenix team's recommended default. LiveComponents would add unnecessary complexity for stateless rendering.
- **Tradeoff acknowledged:** If a tab ever needs its own stateful behavior (e.g., an interactive sub-form), it would need to be converted to a LiveComponent. Unlikely for the current feature set.

### Decision 2: Slide-over panel vs separate page for team detail

- **Decision:** Replace TeamDetailLive (separate page at `/runs/:id/teams/:name`) with a slide-over panel rendered within RunDetailLive.
- **Alternatives considered:** Keep as separate page; modal dialog; accordion expansion within the team card grid.
- **Why:** A slide-over keeps the run context visible (tabs, status cards) while showing team detail. It avoids a full page navigation and back-button dance. The accordion approach was rejected because the team detail content (logs, diagnostics, resume actions) is too large for inline expansion. A modal was rejected because it obscures the run context.
- **Tradeoff acknowledged:** The slide-over adds complexity to RunDetailLive's assigns (panel state, panel-specific data). Team detail content that previously had its own LiveView process now shares the RunDetailLive process. If a team has very large logs, this could increase memory for that LiveView. Mitigated by the existing `@max_log_lines 500` cap.

### Decision 3: Inline compare vs separate page

- **Decision:** Fold RunCompareLive into RunListLive as an inline "compare mode."
- **Alternatives considered:** Keep as separate page (status quo); drawer/panel from run detail.
- **Why:** Comparison is a list-level operation -- you select runs from the list. Having it as a separate page forces users to mentally map between two pages. Inline comparison keeps selections visible alongside the list. The RunCompareLive is only 250 LOC of mostly table rendering, so it integrates cleanly.
- **Tradeoff acknowledged:** RunListLive gets slightly more complex (compare mode state + toggle logic). If the compare feature grows significantly (e.g., diff view of configs), it may want its own page again.

### Decision 4: Mode-conditional tab list via pattern matching

- **Decision:** A `visible_tabs/1` function pattern-matches on `run.mode` to return the tab list for the tab bar.
- **Alternatives considered:** Show all tabs always with "N/A" content for inapplicable modes; nested conditionals in the template.
- **Why:** Showing irrelevant tabs (e.g., "Knowledge" for a DAG run) confuses users and adds visual noise. Pattern matching is clean, exhaustive, and easy to extend when new modes are added. The alternative of conditional rendering in the template is what we have today -- scattered `if non_dag?(@run)` checks -- and it's the root cause of the god-module problem.
- **Tradeoff acknowledged:** Users switching between runs of different modes will see the tab bar change shape. This is intentional and correct -- the tabs reflect what the mode offers.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Breaking existing PubSub event handlers during extraction

- **Risk:** Extracting tabs into separate modules could disconnect event handlers from the assigns they update, or break the flow where `handle_info` updates assigns that a tab component reads.
- **Impact:** Run detail page stops updating in real-time. Running runs appear frozen.
- **Mitigation:** Extract one tab at a time. After each extraction, run `mix test test/cortex_web/live/run_detail_live_test.exs` and manually verify real-time updates with a running workflow. The key insight: `handle_info` stays in RunDetailLive and updates assigns. Tab components just read assigns. So event handling is unaffected by extraction.
- **Validation time:** ~10 minutes per tab (run tests + manual check).

### Risk 2: Slide-over panel memory pressure from large team logs

- **Risk:** Loading a team's 500-line log into RunDetailLive's assigns (previously in TeamDetailLive's separate process) could increase per-connection memory.
- **Impact:** Higher memory usage when panel is open. Negligible for single users; could matter at scale.
- **Mitigation:** The existing `@max_log_lines 500` cap already bounds this. Additionally, clear panel assigns (`log_lines: nil`, `diagnostics_report: nil`) on panel close. Measure with `:observer` before/after.
- **Validation time:** ~5 minutes to check memory with observer.

### Risk 3: Removing routes breaks bookmarked URLs

- **Risk:** Users who bookmarked `/runs/compare`, `/runs/:id/teams/:name`, or `/jobs` get 404s.
- **Impact:** Broken bookmarks, confusing UX.
- **Mitigation:** Add redirect routes in the router: `/runs/compare` redirects to `/runs`, `/runs/:id/teams/:name` redirects to `/runs/:id` (with a flash message), `/jobs` redirects to `/runs`. These are 3 one-line redirects.
- **Validation time:** ~5 minutes to add redirects and test.

### Risk 4: RunDetailLive extraction introduces compile errors from private function references

- **Risk:** Tab templates reference private helper functions (`defp`) in RunDetailLive. Extracting templates to separate modules means those functions need to become public or be moved.
- **Impact:** Compile failures, blocked progress.
- **Mitigation:** Before extraction, audit all `defp` functions called from each tab's template section. Shared helpers (formatters, status badges) move to a `RunDetailHelpers` module. Tab-specific helpers move with their tab component. Do this audit in task 1 before any code changes.
- **Validation time:** ~10 minutes to audit with grep.

### Risk 5: Credo/format violations from extracted modules

- **Risk:** New module files may not follow project conventions (missing @moduledoc, wrong formatting).
- **Impact:** CI fails on `mix credo --strict` or `mix format --check-formatted`.
- **Mitigation:** Run `mix format` and `mix credo --strict` after every task. Follow the project's coding style: `@moduledoc`, `@doc`, `@spec` on public functions.
- **Validation time:** ~2 minutes.

---

## Recommended API Surface

### RunListLive
- Existing: `filter_status`, `sort`, `delete_run`, `next_page`, `prev_page`
- New: `toggle_compare` (enter/exit compare mode), `toggle_select_run` (select run for comparison)

### RunDetailLive
- Existing: all current `handle_event` and `handle_info` handlers stay
- New: `open_team_panel(team)`, `close_team_panel()`, `retry_run()`
- Modified: `visible_tabs(run)` returns mode-appropriate tab list

### Removed LiveViews
- `RunCompareLive` -- logic absorbed into RunListLive
- `TeamDetailLive` -- logic absorbed into RunDetailLive slide-over
- `JobsLive` -- per-run jobs already in RunDetailLive

---

## Folder Structure

```
lib/cortex_web/
  live/
    run_list_live.ex                    # Enhanced with compare mode (MODIFY)
    run_detail_live.ex                  # Slimmed to ~500 LOC coordinator (MODIFY)
    run_detail/
      overview_tab.ex                   # CREATE - status cards, team cards, activity feed
      graph_tab.ex                      # CREATE - DAG tier visualization
      membership_tab.ex                 # CREATE - Mesh SWIM states
      knowledge_tab.ex                  # CREATE - Gossip round progress
      activity_tab.ex                   # CREATE - full activity feed
      messages_tab.ex                   # CREATE - message viewer + sender
      logs_tab.ex                       # CREATE - log viewer
      diagnostics_tab.ex               # CREATE - diagnostics + debug reports
      summaries_tab.ex                  # CREATE - agent + DB summaries
      jobs_tab.ex                       # CREATE - per-run internal jobs
      settings_tab.ex                   # CREATE - run config + metadata
      team_slide_over.ex                # CREATE - slide-over panel component
      helpers.ex                        # CREATE - shared formatters, status helpers
    run_compare_live.ex                 # DELETE (logic moves to run_list_live)
    team_detail_live.ex                 # DELETE (logic moves to slide-over)
    jobs_live.ex                        # DELETE (already in run detail)
  components/
    compare_panel.ex                    # CREATE - inline compare table component
    run_mode_icon.ex                    # CREATE - DAG/Mesh/Gossip icon
    core_components.ex                  # MODIFY - add slide_over component
    dag_components.ex                   # KEEP - unchanged
  router.ex                            # MODIFY - remove 3 routes, add redirects

test/cortex_web/live/
  run_list_live_test.exs                # MODIFY - add compare mode tests
  run_detail_live_test.exs              # MODIFY - add mode-specific tab tests
  run_detail/
    overview_tab_test.exs               # CREATE
    graph_tab_test.exs                  # CREATE
    membership_tab_test.exs             # CREATE
    knowledge_tab_test.exs              # CREATE
    team_slide_over_test.exs            # CREATE
```

---

## Step-by-Step Task Plan

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Extract tab components from RunDetailLive

- **Outcome:** RunDetailLive's 8 tab render blocks are moved into 11 function component modules under `run_detail/`. RunDetailLive's `render/1` calls these components. All `handle_event` and `handle_info` remain in RunDetailLive. Shared `defp` helpers move to `run_detail/helpers.ex`.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/run_detail/overview_tab.ex`, `activity_tab.ex`, `messages_tab.ex`, `logs_tab.ex`, `diagnostics_tab.ex`, `summaries_tab.ex`, `jobs_tab.ex`, `settings_tab.ex`, `graph_tab.ex`, `membership_tab.ex`, `knowledge_tab.ex`, `helpers.ex`
  - Modify: `lib/cortex_web/live/run_detail_live.ex` (render delegates to components, defp helpers moved out)
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/run_detail_live_test.exs
  mix credo --strict
  ```
- **Suggested commit message:** `refactor(web): extract RunDetailLive tabs into function components`

### Task 2: Add mode-conditional tab bar

- **Outcome:** Tab bar renders only the tabs relevant to the run's mode. `visible_tabs/1` function returns the correct tab list per mode. DAG runs show "Graph" instead of inline mesh/gossip content. Mesh runs show "Membership". Gossip runs show "Knowledge".
- **Files to create/modify:**
  - Modify: `lib/cortex_web/live/run_detail_live.ex` (add `visible_tabs/1`, update tab bar render)
  - Modify: `lib/cortex_web/live/run_detail/overview_tab.ex` (remove mode-specific content that now has its own tab)
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/run_detail_live_test.exs
  mix credo --strict
  ```
- **Suggested commit message:** `feat(web): mode-conditional tab bar for DAG/Mesh/Gossip runs`

### Task 3: Replace TeamDetailLive with slide-over panel

- **Outcome:** Clicking a team/agent/node card opens a slide-over panel within RunDetailLive. Panel shows result, logs, diagnostics, resume/restart. TeamDetailLive is deleted. Route removed. Redirect added.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/run_detail/team_slide_over.ex`
  - Modify: `lib/cortex_web/live/run_detail_live.ex` (add panel assigns, open/close events)
  - Modify: `lib/cortex_web/live/run_detail/overview_tab.ex` (team card links become phx-click)
  - Modify: `lib/cortex_web/router.ex` (remove team route, add redirect)
  - Modify: `lib/cortex_web/components/core_components.ex` (add `slide_over` component if needed)
  - Delete: `lib/cortex_web/live/team_detail_live.ex`
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/run_detail_live_test.exs
  mix test test/cortex_web/live/
  mix credo --strict
  ```
- **Suggested commit message:** `feat(web): replace TeamDetailLive with slide-over panel in RunDetail`

### Task 4: Fold RunCompareLive into RunListLive

- **Outcome:** RunListLive has a "Compare" toggle. Selecting runs shows an inline comparison table. RunCompareLive is deleted. Route removed. Redirect added.
- **Files to create/modify:**
  - Create: `lib/cortex_web/components/compare_panel.ex`
  - Modify: `lib/cortex_web/live/run_list_live.ex` (add compare mode assigns, events, render)
  - Modify: `lib/cortex_web/router.ex` (remove compare route, add redirect)
  - Delete: `lib/cortex_web/live/run_compare_live.ex`
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/run_list_live_test.exs
  mix credo --strict
  ```
- **Suggested commit message:** `feat(web): inline run comparison in RunListLive, remove RunCompareLive`

### Task 5: Remove standalone JobsLive and add mode icon component

- **Outcome:** `/jobs` route removed with redirect to `/runs`. JobsLive deleted. Sidebar no longer shows "Jobs" item (sidebar change owned by another role, but this task removes the route). Mode icon component created and used in RunListLive's status column.
- **Files to create/modify:**
  - Create: `lib/cortex_web/components/run_mode_icon.ex`
  - Modify: `lib/cortex_web/live/run_list_live.ex` (use mode icon in status column)
  - Modify: `lib/cortex_web/router.ex` (remove /jobs route, add redirect)
  - Delete: `lib/cortex_web/live/jobs_live.ex`
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/run_list_live_test.exs
  mix test
  mix credo --strict
  ```
- **Suggested commit message:** `feat(web): remove standalone Jobs page, add run mode icon component`

### Task 6: Add tests for new components and consolidated flows

- **Outcome:** Test coverage for tab component rendering, mode-conditional tabs, slide-over panel, compare mode, and route redirects.
- **Files to create/modify:**
  - Create: `test/cortex_web/live/run_detail/overview_tab_test.exs`, `graph_tab_test.exs`, `membership_tab_test.exs`, `knowledge_tab_test.exs`, `team_slide_over_test.exs`
  - Modify: `test/cortex_web/live/run_list_live_test.exs` (compare mode tests)
  - Modify: `test/cortex_web/live/run_detail_live_test.exs` (mode tab tests, slide-over tests)
- **Exact verification command(s):**
  ```bash
  mix test
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `test(web): add tests for runs consolidation — tabs, slide-over, compare`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Runs Consolidation Designer

**Architecture updates:**
- Run detail tabs: `lib/cortex_web/live/run_detail/` (11 function component modules + helpers)
- Shared components: `lib/cortex_web/components/` (compare_panel, run_mode_icon, slide_over in core)

**Coding style rules:**
- Tab components use `use Phoenix.Component` (not LiveComponent) -- they are stateless
- All tab components receive assigns from RunDetailLive; they do NOT subscribe to PubSub
- Shared helpers for formatting (tokens, duration, status badges) live in `run_detail/helpers.ex`
- Mode-specific rendering: use `visible_tabs/1` pattern matching, never inline `if mode == X` in templates

**Dev commands:**
```bash
mix test test/cortex_web/live/run_detail/     # tab component tests
mix test test/cortex_web/live/run_list_live_test.exs  # includes compare mode
```

**Before you commit:**
- Verify mode-conditional tabs render correctly for all 3 modes (DAG, Mesh, Gossip)
- Verify slide-over panel opens/closes without navigation events
- Verify all PubSub events still trigger real-time updates

**Guardrails:**
- Do not add new PubSub subscriptions in tab components -- only RunDetailLive subscribes
- Do not convert function components to LiveComponents without documenting why
- Redirect removed routes -- never leave a 404 for a previously valid URL

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- Runs flow: `/runs` (list with optional compare) -> `/runs/:id` (detail with mode-adaptive tabs) -> slide-over panel for team drill-down
- RunDetailLive is the coordinator process: owns PubSub, assigns, event handling
- Tab components are stateless renderers: receive assigns, return HEEx
- Mode-conditional tabs: `visible_tabs/1` pattern matches on `run.mode` to control tab bar

### Key Engineering Decisions + Tradeoffs
- Function components over LiveComponents: zero overhead, simpler mental model, but can't hold their own state
- Slide-over panel over separate page: preserves run context, avoids navigation, but shares LiveView process memory
- Inline compare over separate page: natural list-level operation, but adds complexity to RunListLive
- Mode-conditional tabs over show-all-with-N/A: cleaner UX, but tab bar changes shape between runs

### Limits of MVP + Next Steps
- No run grouping/project support (sort by name as workaround)
- No batch operations on multiple runs (delete multiple, compare > 2 with charts)
- Retry action requires the same config_yaml -- no edit-and-retry flow
- Future: WebSocket-based slide-over could live-stream team logs without polling

### How to Run Locally + How to Validate
- `mix phx.server` and visit `http://localhost:4000/runs`
- Create runs in all 3 modes (DAG, Mesh, Gossip) to verify tab rendering
- Click a team card to verify slide-over opens without page navigation
- Toggle compare mode to verify inline comparison table

---

## READY FOR APPROVAL
