# Agents Page Designer Plan

## You are in PLAN MODE.

### Project
I want to do a **UI Restructure** of the Cortex web application.

**Goal:** build a **unified Agents page** that merges the current Cluster, Mesh topology, and agent discovery views into a single fleet dashboard — the foundational view of every agent connected to Cortex, regardless of transport or coordination mode.

### Role + Scope (fill in)
- **Role:** Agents Page Designer
- **Scope:** Design the new `/agents` page and `/agents/:id` detail view. Owns the agent grid/list, capability filtering, topology visualization mode, agent detail panel, real-time updates, and empty state. Does NOT own the sidebar layout (Information Architect), shared component contracts (Component Architect), run-level agent views (Runs Consolidation Designer), or workflow agent picker (Workflows Page Designer).
- **File you will write:** `/docs/ui-restructure/plans/agents-page.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1 — Agent Fleet Grid/List:** Display all connected agents (gateway + local) in a responsive grid with toggle to list view. Each card shows: name, role, capabilities (as tags), transport type (gRPC/WS/local badge), status (idle/working/draining/disconnected), health indicator, last heartbeat relative time.
- **FR2 — Capability-Based Filtering and Search:** Free-text search bar that matches agent name, role, and capabilities. Capability tag filter chips — click a capability to filter to agents that advertise it. Status filter dropdown (all / idle / working / draining / disconnected). Transport filter (all / gRPC / WebSocket / local).
- **FR3 — Agent Detail Panel:** Slide-over panel (right side) or dedicated `/agents/:id` route showing: full agent metadata, status history, current load (active_tasks, queue_depth), capabilities list, transport/connection info, recent work history (runs this agent participated in), and live messages if in an active mesh session.
- **FR4 — Topology Visualization Mode:** Toggle button to switch from grid view to topology graph view. Adapts the SVG topology renderer from current MeshLive. Shows all agents as nodes with edges representing active mesh connections. Nodes are colored by status, clickable to open detail panel. Only shows edges when agents are in an active mesh session; otherwise shows disconnected nodes in a circle layout.
- **FR5 — Real-Time Updates:** Subscribe to `Cortex.Events` and `Cortex.Gateway.Events` PubSub. Agent connect/disconnect updates the grid immediately with flash notification. Status changes update badge colors in-place. Heartbeat staleness refreshes every 5 seconds (existing pattern from ClusterLive).
- **FR6 — Agent Grouping:** Group agents by status (connected vs disconnected), by transport type, or by capability. Default grouping: none (flat list sorted by name). Optional group-by selector.
- **FR7 — Active Run Linking:** If an agent's status is `:working`, show the run it's participating in with a link to `/runs/:id`. Pull from run metadata or maintain an agent-to-run mapping in the LiveView assigns.
- **FR8 — Empty State:** When no agents are connected, show a centered illustration with clear guidance: "No agents connected. Deploy a sidecar or start a local agent to get started." with links to docs.
- **Tests required:** LiveView tests for mount, PubSub event handling, search/filter interactions, topology toggle, empty state rendering.
- **Metrics required:** N/A — web-only restructure, no new backend metrics.

## Non-Functional Requirements

- Language/runtime: Elixir/Phoenix LiveView (existing stack)
- Local dev: `mix phx.server` — no additional services required
- Observability: N/A — web layer only
- Safety: No user input is persisted or executed; display-only page reading from existing GenServer state
- Documentation: CLAUDE.md + EXPLAIN.md contributions (see below)
- Performance: Page must render with 100+ agents without layout thrash. Topology SVG should handle up to 50 nodes smoothly. PubSub updates should not cause full-page re-renders (use targeted assigns).

---

## Assumptions / System Model

- **Deployment environment:** Local dev (mix phx.server); later Docker/k8s — no impact on this page's design.
- **Failure modes:** Gateway Registry GenServer unavailable at mount (handled with existing `rescue` pattern returning `[]`). PubSub subscription failure (silent fallback). Agent data stale if heartbeat timer stops (UI shows relative time, staleness is self-evident).
- **Data sources:** `Cortex.Gateway.Registry.list/0` returns `[RegisteredAgent.t()]`. `Cortex.Gateway.Registry.list_by_capability/1` for filtered queries. `Cortex.Gateway.Registry.get/1` for detail view. All calls are synchronous GenServer calls.
- **Agent identity:** Gateway agents have UUID `id`, `name`, `role`, `capabilities`, `status`, `transport`, `metadata`, `registered_at`, `last_heartbeat`, `load`. Local agents (from `Cortex.Agent.Registry`) may have a different struct — need to normalize into a common display struct or read only gateway agents in Phase 1.
- **Multi-tenancy:** None — single-tenant control plane.

---

## Data Model (as relevant to your role)

This page reads existing data; no new persistence. The display model is derived from `Cortex.Gateway.RegisteredAgent`:

- **AgentCard (display struct, in LiveView assigns)**
  - `id` — UUID string
  - `name` — string
  - `role` — string or nil
  - `capabilities` — list of strings
  - `status` — :idle | :working | :draining | :disconnected
  - `transport` — :websocket | :grpc | :local
  - `last_heartbeat` — DateTime or nil
  - `registered_at` — DateTime or nil
  - `load` — %{active_tasks: integer, queue_depth: integer}
  - `active_run_id` — string or nil (for linking to runs)

No validation rules needed — data comes from the trusted Gateway Registry GenServer.

No versioning — read-only display of live state.

No new persistence — all state is in-memory via existing GenServer.

---

## APIs (as relevant to your role)

### Existing Backend APIs (consumed, not modified)

The Agents page reads from existing backend APIs. No new endpoints needed.

- `Cortex.Gateway.Registry.list/0` — returns all registered agents
- `Cortex.Gateway.Registry.list_by_capability/1` — returns agents matching a capability string
- `Cortex.Gateway.Registry.get/1` — returns a single agent by ID
- `Cortex.Gateway.Registry.count/0` — returns agent count (for dashboard stat card)

### PubSub Events (consumed, not modified)

- `:agent_registered` — payload: `%{agent_id, name, role, capabilities}`
- `:agent_unregistered` — payload: `%{agent_id, name, reason}`
- `:agent_status_changed` — payload: `%{agent_id, old_status, new_status}`

### LiveView Routes (new)

- `GET /agents` — AgentsLive, :index (fleet grid/list with optional topology mode)
- `GET /agents/:id` — AgentsLive, :show (detail panel open for specific agent)

### LiveView Events (new, client-side)

- `"toggle_view"` — switch between grid and topology views
- `"toggle_layout"` — switch between grid and list layouts (within non-topology mode)
- `"search"` — update search query (phx-debounce="300")
- `"filter_status"` — filter by status atom
- `"filter_transport"` — filter by transport type
- `"filter_capability"` — toggle a capability filter tag
- `"clear_filters"` — reset all filters
- `"select_agent"` — open agent detail panel (set selected_agent_id)
- `"close_detail"` — close agent detail panel
- `"group_by"` — change grouping mode (none / status / transport / capability)

---

## Architecture / Component Boundaries (as relevant)

### New Modules

1. **`CortexWeb.AgentsLive`** (~400-600 LOC)
   - Main LiveView module for `/agents` and `/agents/:id`
   - Owns: mount, PubSub subscriptions, event handlers, filter/search state
   - Renders: page layout, toolbar, conditional grid/topology view
   - Delegates component rendering to function components (inline or in a component module)

2. **`CortexWeb.AgentsLive` internal components** (render functions within the module)
   - `agent_card/1` — individual agent card for grid view
   - `agent_row/1` — individual agent row for list view
   - `agent_detail_panel/1` — slide-over detail panel
   - `topology_view/1` — SVG topology graph (extracted from MeshLive's topology_svg)
   - `filter_toolbar/1` — search bar + filter chips + view toggle
   - `empty_state/1` — no-agents guidance

### Component Dependencies (from Component Architect)

The Agents page will consume these shared components once they exist:
- Agent card component (shared with Workflow agent picker, Run team list)
- Status badge component (shared status color system)
- Topology visualizer component (shared with Run detail topology)

Until the Component Architect delivers these, the Agents page will use inline function components that follow the agreed-upon interface contract.

### Data Flow

```
Gateway Registry (GenServer)
    |
    |-- list/0 on mount --> assigns.agents
    |-- get/1 on select --> assigns.selected_agent
    |
PubSub (Cortex.Events + Cortex.Gateway.Events)
    |
    |-- :agent_registered --> add to assigns.agents, flash
    |-- :agent_unregistered --> remove from assigns.agents, flash
    |-- :agent_status_changed --> update status in assigns.agents
    |
Timer (every 5s)
    |
    |-- :refresh_heartbeats --> update assigns.now for relative times
    |
Client Events (phx-click, phx-change)
    |
    |-- search/filter --> update assigns.search_query, assigns.filters
    |-- toggle_view --> update assigns.view_mode (:grid | :topology)
    |-- select_agent --> update assigns.selected_agent_id
```

### Config changes propagation
Not applicable — no configuration to propagate.

### Concurrency model
Single LiveView process per connection. PubSub broadcasts handled via `handle_info`. No worker pools or background tasks.

### Backpressure strategy
The 5-second heartbeat refresh timer is the only recurring work. Agent list is bounded by actual connected agents (unlikely to exceed hundreds in practice).

---

## Correctness Invariants (must be explicit)

1. **Agent list is always consistent with Gateway Registry:** On mount, `assigns.agents` reflects `Registry.list/0`. PubSub events incrementally update the list. If an `:agent_registered` event arrives, the agent appears in the grid within the next render cycle.
2. **Agent unregistration removes the agent from all views:** Grid, list, topology graph, and detail panel all reflect the removal. If the detail panel is showing a disconnected agent, it remains visible but shows disconnected status.
3. **Filters are purely client-side:** Filtering and search operate on `assigns.agents` in the render function (or a derived `assigns.filtered_agents`). No backend calls for filtering.
4. **Topology edges only exist between agents in an active mesh session:** Nodes without active mesh connections appear as isolated nodes in the topology view.
5. **Empty state renders when and only when `assigns.agents == []`:** No flicker — the empty state should not flash briefly before agents load.
6. **Heartbeat staleness is computed from `assigns.now`:** Updated every 5 seconds. No stale relative times.
7. **Search is debounced at 300ms:** Typing in the search box does not trigger a server round-trip on every keystroke.

---

## Tests

### Unit Tests

- **`test/cortex_web/live/agents_live_test.exs`**
  - `mount/3` renders agent grid with agents from Registry
  - `mount/3` renders empty state when no agents registered
  - `handle_info(:agent_registered)` adds agent to grid
  - `handle_info(:agent_unregistered)` removes agent from grid
  - `handle_info(:agent_status_changed)` updates status badge
  - `handle_info(:refresh_heartbeats)` updates `now` assign
  - `handle_event("search")` filters agents by name/role/capability
  - `handle_event("filter_status")` filters agents by status
  - `handle_event("filter_transport")` filters agents by transport
  - `handle_event("toggle_view")` switches between grid and topology
  - `handle_event("select_agent")` opens detail panel
  - `handle_event("close_detail")` closes detail panel
  - Detail panel shows agent metadata, capabilities, load

### Integration Tests

- Mount page with multiple agents registered via Gateway Registry, verify all render
- Register a new agent while page is mounted, verify it appears
- Unregister an agent while page is mounted, verify it disappears
- Search for an agent by capability, verify filtering works

### Failure Injection Tests

- Gateway Registry unavailable at mount — page renders with empty state (no crash)
- PubSub subscription fails — page renders but no live updates (graceful degradation)

### Commands

```bash
mix test test/cortex_web/live/agents_live_test.exs
mix test test/cortex_web/live/agents_live_test.exs --trace
```

---

## Benchmarks + "Success"

N/A — this is a UI page, not a data pipeline. Performance is validated qualitatively:
- Page renders in <100ms with 50 agents
- Topology SVG renders without jank for up to 50 nodes
- PubSub updates apply without visible flicker

No benchmark commands needed. LiveView test suite validates correctness.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Single LiveView module with inline components vs separate component module

- **Decision:** Use a single `AgentsLive` module with private function components (like current `ClusterLive` and `MeshLive`).
- **Alternatives considered:** Separate `AgentsComponents` module with public function components.
- **Why:** The existing codebase pattern (ClusterLive, MeshLive, GossipLive) keeps components inline. Following this pattern reduces cognitive overhead and avoids premature abstraction. Once the Component Architect delivers shared components, the inline components can be replaced.
- **Tradeoff acknowledged:** If the module exceeds ~800 LOC, readability suffers. Mitigation: extract to a component module at that point. Estimated LOC is 400-600, within comfortable range.

### Decision 2: Client-side filtering vs server-side filtering

- **Decision:** All filtering (search, status, transport, capability) happens in the render path by filtering `assigns.agents` into a derived list. No additional GenServer calls for filtered views.
- **Alternatives considered:** Call `Registry.list_by_capability/1` for capability filters, re-query Registry on every filter change.
- **Why:** The agent list is small (tens to low hundreds) and already fully loaded in assigns. Client-side filtering is instant and avoids GenServer call overhead. `list_by_capability/1` only filters by one capability — we need multi-dimensional filtering (status + transport + capability + text search) which is trivial in Elixir list operations.
- **Tradeoff acknowledged:** If agent counts grow to thousands, client-side filtering would be slow. This is unlikely for the control plane use case, and can be revisited.

### Decision 3: Slide-over detail panel vs separate route

- **Decision:** Support both — `/agents` shows the grid, clicking an agent opens a slide-over panel AND updates the URL to `/agents/:id`. Navigating directly to `/agents/:id` opens the page with the panel pre-opened. The panel is a `<div>` within the same LiveView, not a separate page.
- **Alternatives considered:** Separate LiveView at `/agents/:id` (full page detail), or panel-only without URL update.
- **Why:** Slide-over keeps context (you see the fleet while inspecting one agent). URL update enables deep-linking and browser back navigation. This matches modern fleet dashboards (Kubernetes Dashboard, Datadog Infrastructure). Using `handle_params` with live_action `:show` is idiomatic Phoenix LiveView.
- **Tradeoff acknowledged:** Slightly more complex LiveView with `handle_params` routing. But this is a well-understood Phoenix pattern.

### Decision 4: Topology SVG extraction strategy

- **Decision:** Copy the topology SVG rendering logic from MeshLive into AgentsLive initially, then refactor into a shared component when the Component Architect delivers the topology visualizer contract.
- **Alternatives considered:** Extract immediately into a shared module before building the Agents page.
- **Why:** The MeshLive topology renderer is tightly coupled to mesh member state (`:alive`, `:suspect`, `:dead`). The Agents page needs to render a different data shape (gateway agents with `:idle`, `:working` etc). Copying and adapting is faster than designing the general abstraction first. The Component Architect's shared topology component will eventually replace both copies.
- **Tradeoff acknowledged:** Temporary code duplication. Accepted as a deliberate phasing strategy — duplication is removed in the Component Architect's task.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Local agents not in Gateway Registry

- **Risk:** The Gateway Registry only tracks externally connected agents (gRPC/WebSocket). Locally-spawned agents (via `Cortex.Agent.Registry`) use a different registry with a different data model. The Agents page might show an incomplete picture.
- **Impact:** Users see only gateway agents, not local agents. Confusing if running in local dev mode.
- **Mitigation:** Phase 1 shows only gateway agents (the primary production use case). Add a note in the empty state about local agents. Phase 2 adds a normalizer that reads from both registries and presents a unified list.
- **Validation time:** 5 minutes — check `Cortex.Agent.Registry` API and compare struct fields.

### Risk 2: Topology view with no active mesh sessions

- **Risk:** The topology view is most useful when agents are in an active mesh session with real connections. Without an active session, the topology is just disconnected nodes in a circle — not very informative.
- **Impact:** Users toggle to topology view and see a meaningless circle of dots. Poor UX.
- **Mitigation:** When no active mesh session exists, show a clear message: "No active mesh session. Agents are shown as available nodes. Start a mesh run to see live connectivity." Still render the nodes so users can see the fleet shape. Consider adding "potential connections" as dashed lines.
- **Validation time:** 5 minutes — mock up both states mentally and verify the UX makes sense.

### Risk 3: Agent-to-Run linking data not available

- **Risk:** The Gateway Registry tracks agent status (`:working`) but not which run the agent is working on. There's no built-in mapping from agent ID to active run ID.
- **Impact:** FR7 (Active Run Linking) cannot be implemented without additional state tracking.
- **Mitigation:** Phase 1 shows status only, without run links. Phase 2 adds an agent-to-run index in the LiveView (populated by listening to `:run_started` / `:run_completed` events that include agent lists). This is a display-layer concern — no backend changes needed.
- **Validation time:** 10 minutes — trace the run start flow to confirm whether agent IDs are included in run events.

### Risk 4: MeshLive topology code harder to adapt than expected

- **Risk:** MeshLive's topology SVG uses mesh-specific concepts (incarnation, suspect/dead states, full-mesh edge generation) that don't map cleanly to gateway agent status.
- **Impact:** More adaptation work than a simple copy-paste. Could delay the topology view.
- **Mitigation:** The core SVG rendering (circle layout, node circles, edge lines, click handlers) is generic. Only the state-to-color mapping and edge logic need changing. Estimated 1-2 hours of adaptation, not a blocker.
- **Validation time:** 10 minutes — read MeshLive topology_svg/1 and identify mesh-specific vs generic parts.

### Risk 5: Coordination with Component Architect on component contracts

- **Risk:** The Component Architect may define component interfaces that conflict with the Agents page's internal components, requiring rework.
- **Impact:** Wasted work if inline components need significant reshaping.
- **Mitigation:** Keep inline components simple with clear assigns interfaces (`agent`, `on_click`, etc.) that map naturally to function component signatures. Review Component Architect's plan before implementation begins.
- **Validation time:** 5 minutes — once Component Architect plan is available, diff the interfaces.

---

# Please produce (no code yet):

## 1) Recommended API Surface

### LiveView Module: `CortexWeb.AgentsLive`

**Mount:**
- `mount/3` — loads agents from Gateway Registry, initializes filters, subscribes to PubSub
- `handle_params/3` — handles `:index` (grid view) and `:show` (detail panel open for `:id`)

**PubSub Handlers (handle_info):**
- `:agent_registered` — add agent to assigns, flash notification
- `:agent_unregistered` — remove agent from assigns, flash notification, close detail if selected
- `:agent_status_changed` — update agent status in assigns
- `:refresh_heartbeats` — update `assigns.now` for relative time display

**Client Event Handlers (handle_event):**
- `"search"` — update `assigns.search_query`
- `"filter_status"` — update `assigns.status_filter`
- `"filter_transport"` — update `assigns.transport_filter`
- `"filter_capability"` — toggle capability in `assigns.capability_filters`
- `"clear_filters"` — reset all filter assigns
- `"toggle_view"` — switch `assigns.view_mode` between `:grid` and `:topology`
- `"toggle_layout"` — switch `assigns.layout` between `:cards` and `:rows`
- `"select_agent"` — navigate to `/agents/:id` (opens detail panel)
- `"close_detail"` — navigate back to `/agents` (closes detail panel)
- `"group_by"` — update `assigns.group_by`

**Render Components (private functions):**
- `filter_toolbar/1` — search bar, filter dropdowns, view/layout toggles
- `agent_grid/1` — responsive card grid
- `agent_card/1` — individual agent card
- `agent_list/1` — table/list layout
- `agent_row/1` — individual agent row
- `agent_detail_panel/1` — slide-over with full agent info
- `topology_view/1` — SVG agent graph (adapted from MeshLive)
- `empty_state/1` — no-agents guidance

## 2) Folder Structure

```
lib/cortex_web/
  live/
    agents_live.ex           # NEW — main Agents LiveView (400-600 LOC)
  # No new directories needed — follows existing flat LiveView structure

test/cortex_web/
  live/
    agents_live_test.exs     # NEW — LiveView tests
```

The Agents page does NOT create new backend modules. It reads from existing:
- `lib/cortex/gateway/registry.ex`
- `lib/cortex/gateway/registered_agent.ex`
- `lib/cortex/gateway/events.ex`

## 3) Step-by-Step Task Plan

### Task 1: Scaffold AgentsLive with mount + empty state
- Create `agents_live.ex` with `mount/3` that reads from Gateway Registry
- Render empty state when no agents connected
- Add route to router.ex: `live("/agents", AgentsLive, :index)` and `live("/agents/:id", AgentsLive, :show)`
- Write initial tests: mount renders, empty state renders
- **Files:** `lib/cortex_web/live/agents_live.ex`, `lib/cortex_web/router.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs`
- **Commit:** `feat(web): scaffold AgentsLive with mount and empty state`

### Task 2: Agent grid + card rendering + list toggle
- Render agent cards in a responsive grid (3-col on xl, 2-col on md, 1-col on sm)
- Each card shows: name, role, capabilities tags, transport badge, status badge, heartbeat
- Add list/table layout toggle
- Subscribe to PubSub for real-time agent connect/disconnect/status updates
- Add 5-second heartbeat refresh timer
- **Files:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs`
- **Commit:** `feat(web): add agent grid/list with real-time PubSub updates`

### Task 3: Search + filter toolbar
- Add search bar with phx-debounce="300" matching name, role, capabilities
- Add status filter dropdown
- Add transport filter dropdown
- Add capability tag filter chips (derived from all capabilities across agents)
- Add "Clear filters" button
- All filtering is client-side on `assigns.agents`
- **Files:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs`
- **Commit:** `feat(web): add capability search and multi-filter toolbar to Agents page`

### Task 4: Agent detail panel (slide-over + URL routing)
- Implement `handle_params/3` for `:show` action
- Render slide-over panel on right side with full agent info
- Show: status, transport, capabilities, load, metadata, registered_at, last_heartbeat
- Clicking an agent navigates to `/agents/:id`, closing navigates back to `/agents`
- Handle edge case: selected agent disconnects while panel is open
- **Files:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs`
- **Commit:** `feat(web): add agent detail slide-over panel with URL routing`

### Task 5: Topology visualization mode
- Add toggle button to switch to topology view
- Adapt MeshLive's SVG topology renderer for gateway agent data
- Circle layout with nodes colored by status
- Edges between agents in active mesh sessions (if available)
- Click node to open detail panel
- Show informational message when no active mesh session
- **Files:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs`
- **Commit:** `feat(web): add topology visualization mode to Agents page`

### Task 6: Grouping + polish + sidebar update
- Add group-by selector (none / status / transport)
- Update sidebar nav in `root.html.heex` to replace Cluster link with Agents link
- Remove or redirect old `/cluster` route (keep `/mesh` and `/gossip` as redirects or remove based on Information Architect plan)
- Final polish: loading states, transitions, accessibility
- Comprehensive test pass
- **Files:** `lib/cortex_web/live/agents_live.ex`, `lib/cortex_web/layouts/root.html.heex`, `lib/cortex_web/router.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Verify:** `mix test test/cortex_web/live/agents_live_test.exs && mix compile --warnings-as-errors && mix format --check-formatted`
- **Commit:** `feat(web): add agent grouping, update sidebar nav, finalize Agents page`

## 4) Benchmark Plan + "Success"

N/A — UI page, not a data pipeline. Success criteria:

- All tests pass (`mix test test/cortex_web/live/agents_live_test.exs`)
- No compiler warnings (`mix compile --warnings-as-errors`)
- Code formatted (`mix format --check-formatted`)
- Credo clean (`mix credo --strict`)
- Page renders correctly with 0, 1, 10, and 50+ agents
- Real-time updates work (agent registration/unregistration reflected immediately)
- Filters and search are responsive
- Topology view renders without errors
- Detail panel opens/closes cleanly with correct URL updates

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Scaffold AgentsLive with mount, routes, and empty state
- **Outcome:** `/agents` route exists, page mounts and renders empty state when no agents connected, basic test coverage
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex` (new), `lib/cortex_web/router.ex` (add routes), `test/cortex_web/live/agents_live_test.exs` (new)
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs ; mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(web): scaffold AgentsLive with mount, routes, and empty state`

### Task 2: Agent grid/list rendering with real-time PubSub updates
- **Outcome:** Agents render as cards in a grid (with list toggle). PubSub events for agent register/unregister/status update the UI in real-time. Heartbeat timer refreshes relative times.
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs`
- **Suggested commit message:** `feat(web): add agent grid/list with real-time PubSub updates`

### Task 3: Search, filtering, and capability discovery
- **Outcome:** Search bar filters by name/role/capability. Status and transport dropdown filters. Capability tag chips for quick filtering. Clear-all button. All client-side.
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs`
- **Suggested commit message:** `feat(web): add search and multi-filter toolbar to Agents page`

### Task 4: Agent detail slide-over panel with URL routing
- **Outcome:** Clicking an agent opens a slide-over panel showing full metadata, capabilities, load, and connection info. URL updates to `/agents/:id` for deep-linking. Panel closes on X or back navigation.
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs`
- **Suggested commit message:** `feat(web): add agent detail slide-over panel with URL routing`

### Task 5: Topology visualization mode
- **Outcome:** Toggle button switches to SVG topology view. Agents rendered as nodes in circle layout, colored by status. Click node to open detail. Informational message when no active mesh.
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs`
- **Suggested commit message:** `feat(web): add topology visualization mode to Agents page`

### Task 6: Grouping, sidebar update, and final polish
- **Outcome:** Group-by selector (none/status/transport). Sidebar updated to show "Agents" nav item. Old Cluster route redirected. All tests pass, credo clean, formatted.
- **Files to create/modify:** `lib/cortex_web/live/agents_live.ex`, `lib/cortex_web/layouts/root.html.heex`, `lib/cortex_web/router.ex`, `test/cortex_web/live/agents_live_test.exs`
- **Exact verification command(s):** `mix test test/cortex_web/live/agents_live_test.exs ; mix compile --warnings-as-errors ; mix format --check-formatted ; mix credo --strict`
- **Suggested commit message:** `feat(web): add grouping, update sidebar, finalize Agents page`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Agents Page Designer

### Coding Style
- Agent display data should be derived from `Cortex.Gateway.RegisteredAgent` — do not create parallel persistence for agent state
- All filtering in AgentsLive is client-side on `assigns.agents` — do not add new GenServer calls for filtered queries
- PubSub event handlers in AgentsLive follow the existing `safe_subscribe` + rescue pattern from ClusterLive/MeshLive
- Topology SVG uses the same viewBox/layout pattern as MeshLive (500x500, circle layout with configurable radius)

### Dev Commands
```bash
mix test test/cortex_web/live/agents_live_test.exs       # agents page tests
mix test test/cortex_web/live/agents_live_test.exs --trace  # verbose
```

### Before You Commit
1. Verify all agent status badges use consistent colors (idle=blue, working=green, draining=yellow, disconnected=red)
2. Verify empty state renders when Gateway Registry returns `[]`
3. Verify search debounce is set to 300ms
4. No `IO.inspect` or `dbg()` left in code

### Guardrails
- Do NOT modify `Cortex.Gateway.Registry` or `Cortex.Gateway.RegisteredAgent` — the Agents page is read-only
- Do NOT add new PubSub event types — consume only existing events
- Do NOT add new database tables or Ecto schemas — agent state is ephemeral GenServer state
- When the Component Architect delivers shared components, replace inline components — do not maintain both

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- The Agents page (`/agents`) is the fleet dashboard — shows all connected agents regardless of transport or coordination mode
- Data flows from `Cortex.Gateway.Registry` GenServer to LiveView assigns on mount, then incrementally updated via PubSub events
- Real-time: agent connect/disconnect and status changes arrive via PubSub broadcast from the Registry GenServer
- Heartbeat freshness is computed client-side by comparing `agent.last_heartbeat` to a `now` assign updated every 5 seconds
- Topology view adapts MeshLive's SVG circle-layout renderer to show agent connectivity

### Key Engineering Decisions + Tradeoffs
- Client-side filtering chosen over server-side because agent lists are small (tens to low hundreds) and multi-dimensional filtering is simpler in Elixir list operations
- Slide-over panel + URL routing chosen over separate page to maintain fleet context while inspecting individual agents
- Inline function components chosen over separate module to match existing codebase patterns (ClusterLive, MeshLive)
- Topology SVG copied-and-adapted from MeshLive rather than extracted into shared component — deliberate phasing; shared component comes from Component Architect

### Limits of MVP + Next Steps
- Phase 1 shows only gateway agents; local agents from `Cortex.Agent.Registry` not yet included
- Agent-to-run linking not implemented in Phase 1 (requires tracking which agents are in which runs)
- Topology edges only shown during active mesh sessions; static "potential connections" are a Phase 2 feature
- Agent groups/clusters are represented via grouping controls, not persistent group definitions

### How to Run Locally + Validate
- `mix phx.server` — navigate to `http://localhost:4000/agents`
- With no agents: should see empty state with guidance
- Start a sidecar agent to see it appear in real-time
- Click an agent card to see the detail panel, verify URL updates to `/agents/:id`
- Toggle topology view to see SVG graph
- Use search and filters to narrow the agent list

---

## READY FOR APPROVAL
