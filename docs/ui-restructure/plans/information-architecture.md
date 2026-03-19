# Information Architecture Plan — Cortex UI Restructure

## You are in PLAN MODE.

### Project
I want to do a **UI restructure of the Cortex web layer**.

**Goal:** Redesign the Cortex web UI from 7 nav items organized around implementation concepts (Dashboard, Runs, Workflows, Gossip, Mesh, Cluster, Jobs) to 4 items organized around user intent (Overview, Agents, Workflows, Runs). Consolidate overlapping pages, kill standalone protocol viewers, and establish the product identity as a multi-agent control plane.

### Role + Scope
- **Role:** Information Architect
- **Scope:** Define the new navigation structure, page hierarchy, URL scheme, and content mapping. Specify what each page shows at an information level. I do NOT own component design, visual design, or implementation code.
- **File I will write:** `docs/ui-restructure/plans/information-architecture.md`
- **No-touch zones:** Do not edit any code files. Do not write implementation.

---

## Functional Requirements
- **FR1:** 4 top-level nav items: Overview, Agents, Workflows, Runs — each with a clear, non-overlapping purpose.
- **FR2:** Every feature currently accessible in the 10 existing LiveView pages must have a defined home in the new structure (nothing silently dropped).
- **FR3:** Deep-linkable URLs for all significant views (run detail, team logs, agent detail, workflow editor).
- **FR4:** Old routes (`/gossip`, `/mesh`, `/cluster`, `/jobs`) must redirect to their new homes during transition.
- **FR5:** Protocol-specific visualizations (gossip topology, mesh membership, DAG graph) become contextual views within Runs, not top-level destinations.
- Tests required: Route-level integration tests verifying all old routes redirect correctly; LiveView mount tests for each new top-level page.
- Metrics required: N/A — no new backend metrics; existing telemetry unchanged.

## Non-Functional Requirements
- Language/runtime: Elixir/Phoenix LiveView (existing stack, no changes)
- Local dev: `mix phx.server` on port 4000 (unchanged)
- Observability: Existing `/metrics` endpoint unchanged
- Safety: All route changes must be backward-compatible via redirects; no data loss
- Documentation: CLAUDE.md updated with new route table; EXPLAIN.md contributions
- Performance: N/A — information architecture only; no new rendering paths defined here

---

## Assumptions / System Model
- Deployment environment: Local dev (mix phx.server); production deployment model unchanged
- The backend (Agent GenServer, Orchestration, Gossip, Mesh, Store, Gateway) is stable and unchanged — this is purely web layer restructure
- The coordination mode (DAG workflow, Mesh, Gossip) is a property of a run, not a standalone product concept
- Gateway agents (connected via gRPC/WebSocket sidecars) are the "real" agents that users care about; internal agents (coordinator, summary-agent, debug-agent) are implementation details shown contextually
- Multi-tenancy: None (unchanged)
- Failure modes: N/A for IA; handled at LiveView level

---

## Data Model (as relevant to this role)

N/A — not in scope for Information Architecture. The existing Ecto schemas (Run, TeamRun, gateway Agent) are unchanged. This plan defines how existing data is surfaced, not how it is stored.

---

## APIs (as relevant to this role)

### Route Definitions (new)

```
GET /                           → OverviewLive      (was DashboardLive)
GET /agents                     → AgentsLive         (new — merges Cluster + gateway agent views)
GET /agents/:id                 → AgentDetailLive    (new — single agent deep-dive)
GET /workflows                  → WorkflowsLive      (was NewRunLive — renamed, same function)
GET /workflows/new              → WorkflowsLive      (alias, redirects to /workflows)
GET /runs                       → RunsLive            (was RunListLive, absorbs RunCompareLive)
GET /runs/compare               → RunsLive            (redirect to /runs with ?view=compare)
GET /runs/:id                   → RunDetailLive       (exists — tabs restructured)
GET /runs/:id/teams/:name       → TeamDetailLive      (exists — unchanged)
```

### Redirect Rules (old → new)

| Old Route | New Destination | Method |
|-----------|----------------|--------|
| `/gossip` | `/runs` with flash "Gossip sessions are now launched and viewed as runs" | 302 redirect |
| `/mesh` | `/runs` with flash "Mesh sessions are now launched and viewed as runs" | 302 redirect |
| `/cluster` | `/agents` | 302 redirect |
| `/jobs` | `/runs` (jobs are now per-run in the run detail jobs tab) | 302 redirect |
| `/runs/compare` | `/runs?view=compare` | 302 redirect |
| `/workflows` | `/workflows` (unchanged path, new module name) | identity |

### API Routes (unchanged)

```
GET  /api/runs              → RunController.index
POST /api/runs              → RunController.create
GET  /api/runs/:id          → RunController.show
GET  /api/runs/:id/teams    → TeamRunController.index
GET  /api/runs/:id/teams/:name → TeamRunController.show
GET  /health/live           → HealthController.live
GET  /health/ready          → HealthController.ready
GET  /metrics               → MetricsController.index
```

---

## Architecture / Component Boundaries (as relevant)

### Page Hierarchy

```
Sidebar (4 items)
├── Overview      /
├── Agents        /agents
├── Workflows     /workflows
└── Runs          /runs
```

### 1. Overview (`/`)

**Purpose:** At-a-glance system health. Answer "is anything on fire?" in 2 seconds.

**Information shown:**
- Stat cards: Total Runs, Active Runs, Total Tokens, Connected Agents (same as current Dashboard)
- Recent Runs table (last 10, same as current Dashboard)
- Quick actions: "+ New Workflow" button, "Compare Runs" link
- System status: gateway health indicator (agent count > 0 = healthy)

**What changes:** Renamed from "Dashboard" to "Overview." Content identical. Module renamed from `DashboardLive` to `OverviewLive`.

### 2. Agents (`/agents`)

**Purpose:** See all agents in the fabric — who is connected, what they can do, what state they're in. This is the "fleet management" view.

**Information shown:**
- Agent count badge in header
- Grid of agent cards (from current ClusterLive): name, transport badge (gRPC/WebSocket), status (idle/working/draining/disconnected), role, capabilities, last heartbeat, registered time, agent ID
- Real-time updates via PubSub (agent_registered, agent_unregistered, agent_status_changed, heartbeat refresh)

**What changes:** ClusterLive content moves here. The page is renamed to "Agents" because users think in terms of agents, not clusters. The URL changes from `/cluster` to `/agents`.

**Agent Detail (`/agents/:id`):**
- Deep-dive into a single agent: full metadata, capabilities list, connection history, current status
- Links to any active runs this agent is participating in
- This is a new page (stretch goal — can be deferred if agent data model doesn't support it yet)

### 3. Workflows (`/workflows`)

**Purpose:** Compose and launch new orchestration runs. This is the "create" action.

**Information shown:**
- YAML editor (paste or load from file path)
- Workspace path input
- Validate button → shows DAG preview, errors, warnings
- Launch button → creates run, redirects to `/runs/:id`

**What changes:** Renamed from "New Run" to "Workflows" (matches mental model: users compose workflows, then launch them as runs). Module renamed from `NewRunLive` to `WorkflowsLive`. The sidebar label changes from "Workflows" to "Workflows" (already correct). URL stays `/workflows`.

**Future consideration:** This page could grow to include a workflow template library, saved workflow drafts, or a visual workflow builder. The IA supports this by giving workflows their own top-level namespace.

### 4. Runs (`/runs`)

**Purpose:** View, filter, sort, compare, and manage all runs. This is the "monitor" view.

**Information shown (list view):**
- Sortable, filterable table of all runs (from current RunListLive)
- Status filter dropdown (all/pending/running/completed/failed)
- Column sorting (name, status, teams, tokens, duration, started)
- Pagination (20 per page)
- Delete action per run
- Mode badge on each run (workflow/gossip/mesh) — indicates the coordination protocol used
- **View toggle:** List view (default) vs Compare view (absorbs RunCompareLive)
  - Compare view shows token breakdown table across completed runs
  - Toggled via `?view=compare` query param or a "Compare" toggle button in the header

**What changes:** RunCompareLive is absorbed into RunsLive as an alternate view mode (toggle between list and compare). The standalone `/runs/compare` route redirects to `/runs?view=compare`.

**Run Detail (`/runs/:id`):**

The existing RunDetailLive stays at `/runs/:id`. Its 8 internal tabs are unchanged:

| Tab | Content | Notes |
|-----|---------|-------|
| Overview | DAG visualization, coordinator status, team status cards, tier progress | Unchanged |
| Activity | Real-time activity feed | Unchanged |
| Messages | Inter-agent messaging (inbox bridge) | Unchanged |
| Logs | Per-team log viewer | Unchanged |
| Summaries | Coordinator summaries, run summary | Unchanged |
| Diagnostics | Per-team diagnostics reports, debug reports | Unchanged |
| Jobs | Internal agent jobs (coordinator, summary-agent, debug-agent) for this run | **Now scoped to this run only** — replaces the need for the global `/jobs` page |
| Settings | Run config YAML, resume/continue controls, name editing | Unchanged |

**Key change for Jobs:** The global `/jobs` page showed jobs across all runs. In the new structure, jobs are accessed per-run via the run detail Jobs tab. If users need a cross-run jobs view, they can navigate to each run individually. This matches the mental model: jobs are internal implementation details of a specific run, not a standalone concern.

**Protocol-specific content in Run Detail:**
- For **DAG workflow** runs: the Overview tab shows the DAG graph (tiers + edges) — unchanged
- For **Gossip** runs: the Overview tab will show gossip topology, round progress, and knowledge entries (content currently in GossipLive, relocated to render within RunDetailLive when `run.mode == "gossip"`)
- For **Mesh** runs: the Overview tab will show mesh membership, failure detection state, and message relay (content currently in MeshLive, relocated to render within RunDetailLive when `run.mode == "mesh"`)

This means `GossipLive` and `MeshLive` are killed as standalone pages. Their visualization logic is extracted into components and rendered conditionally within RunDetailLive's Overview tab based on `run.mode`.

**Team Detail (`/runs/:id/teams/:name`):**
- Unchanged. Shows per-team result, logs, activity, diagnostics.

---

### Feature Migration Map

| Current Location | Feature | New Location | Action |
|-----------------|---------|--------------|--------|
| DashboardLive `/` | Stats + recent runs | OverviewLive `/` | Rename module |
| RunListLive `/runs` | Run list with sort/filter/pagination | RunsLive `/runs` (list mode) | Rename module |
| RunCompareLive `/runs/compare` | Token comparison table | RunsLive `/runs?view=compare` | Merge into RunsLive |
| RunDetailLive `/runs/:id` | 8-tab run detail | RunDetailLive `/runs/:id` | Add protocol-specific overview rendering |
| TeamDetailLive `/runs/:id/teams/:name` | Team detail | TeamDetailLive (unchanged) | No change |
| NewRunLive `/workflows` | YAML editor + DAG preview + launch | WorkflowsLive `/workflows` | Rename module |
| GossipLive `/gossip` | Gossip topology + config + launch | RunDetailLive overview tab (mode=gossip) | Extract components, kill standalone page |
| MeshLive `/mesh` | Mesh membership + config + launch | RunDetailLive overview tab (mode=mesh) | Extract components, kill standalone page |
| ClusterLive `/cluster` | Gateway agent grid | AgentsLive `/agents` | Rename + move |
| JobsLive `/jobs` | Cross-run internal jobs | RunDetailLive jobs tab (per-run) | Kill standalone page |

### Gossip/Mesh Launch Flow

Currently, GossipLive and MeshLive each have their own YAML editor + validate + launch flow (identical pattern to NewRunLive). In the new structure:

1. **WorkflowsLive** (`/workflows`) becomes the single entry point for launching any run, regardless of coordination mode
2. The YAML config determines the mode (DAG workflow, gossip, or mesh)
3. After launch, the user is redirected to `/runs/:id` where the Overview tab renders mode-appropriate visualization
4. The existing `Cortex.Gossip.SessionRunner` and `Cortex.Mesh.SessionRunner` are invoked based on config mode — no backend changes needed

---

### Sidebar Layout

```
┌──────────────────────────┐
│ ◆ Cortex                 │
│ Multi-Agent Orchestration│
├──────────────────────────┤
│ ■ Overview               │  ← /
│ ⊕ Agents                 │  ← /agents (count badge when > 0)
│ ▶ Workflows              │  ← /workflows
│ ≡ Runs                   │  ← /runs (active count badge when > 0)
├──────────────────────────┤
│ v0.1.0                   │
└──────────────────────────┘
```

- Active nav item: highlighted with `text-cortex-400 bg-gray-800` (current pattern)
- Agents item: shows connected agent count badge (from Gateway.Registry.count())
- Runs item: shows active run count badge (runs with status="running")

### Deep-Linking

All significant views are deep-linkable:

| What the user wants to share | URL |
|------------------------------|-----|
| System overview | `/` |
| All agents | `/agents` |
| Specific agent | `/agents/:id` |
| Workflow editor | `/workflows` |
| All runs | `/runs` |
| Run comparison | `/runs?view=compare` |
| Specific run overview | `/runs/:id` |
| Run logs tab | `/runs/:id` (user clicks logs tab — tab state is client-side, not in URL) |
| Team detail | `/runs/:id/teams/:name` |

**Tab state in run detail:** Tabs within `/runs/:id` are currently switched via `phx-click` events without updating the URL. This is acceptable for MVP. A future enhancement could encode the tab in the URL (`/runs/:id?tab=logs`) or use a path segment (`/runs/:id/logs`) for deep-linkable tabs.

---

## Correctness Invariants (must be explicit)

1. **No feature loss:** Every feature accessible in the current 10 LiveView pages has a defined home in the new 4+2 structure (4 top-level + RunDetailLive + TeamDetailLive).
2. **All old routes redirect:** Navigating to `/gossip`, `/mesh`, `/cluster`, `/jobs`, or `/runs/compare` returns a 302 redirect to the appropriate new location.
3. **API routes unchanged:** All `/api/*` and `/health/*` routes remain identical.
4. **PubSub subscriptions preserved:** Every real-time update (run events, gateway events, gossip events, mesh events) continues to reach its destination LiveView.
5. **URL scheme is RESTful:** Resources are nouns (`/agents`, `/runs`, `/workflows`), detail pages use `/:id`, nested resources use parent context (`/runs/:id/teams/:name`).
6. **No backend changes:** Router and LiveView modules change; no changes to `lib/cortex/` business logic.

---

## Tests

- **Route redirect tests:** For each old route (`/gossip`, `/mesh`, `/cluster`, `/jobs`, `/runs/compare`), verify 302 redirect to correct new destination.
  - File: `test/cortex_web/redirects_test.exs`
  - Command: `mix test test/cortex_web/redirects_test.exs`

- **LiveView mount tests:** For each new top-level LiveView (`OverviewLive`, `AgentsLive`, `WorkflowsLive`, `RunsLive`), verify successful mount and page_title assignment.
  - File: `test/cortex_web/live/` (one file per LiveView, following existing pattern)
  - Command: `mix test test/cortex_web/live/`

- **Router test:** Verify all new routes resolve to correct LiveView modules.
  - File: `test/cortex_web/router_test.exs`
  - Command: `mix test test/cortex_web/router_test.exs`

- **Sidebar integration test:** Verify sidebar renders exactly 4 nav items with correct labels and hrefs.
  - Can be part of the layout test or a dedicated test.

Exact commands:
- `mix test` (all pass)
- `mix test test/cortex_web/` (web-layer only)

---

## Benchmarks + "Success"

N/A — Information Architecture does not introduce new rendering paths or data queries. Performance characteristics are unchanged from the existing pages. The renamed/merged LiveViews execute the same queries.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Absorb RunCompareLive into RunsLive via query param toggle

- **Decision:** Merge the compare view into the runs list page as an alternate view mode (`/runs?view=compare`) rather than keeping it as a separate route.
- **Alternatives considered:** (1) Keep `/runs/compare` as a separate LiveView. (2) Make compare a tab within each run's detail page.
- **Why:** The compare view operates on the same data set as the run list (all runs). Having two top-level pages for "looking at runs" creates ambiguity. A toggle within the same page is simpler and reduces nav items. Users comparing runs are already "in" the runs context.
- **Tradeoff acknowledged:** The RunsLive module grows slightly more complex (two rendering modes). This is manageable since the compare view is only ~200 LOC.

### Decision 2: Kill standalone Gossip/Mesh pages; relocate to RunDetailLive

- **Decision:** Remove `/gossip` and `/mesh` as standalone pages. Protocol-specific visualizations render inside RunDetailLive's Overview tab based on `run.mode`.
- **Alternatives considered:** (1) Keep `/gossip` and `/mesh` as standalone pages but move them under `/runs/gossip` and `/runs/mesh`. (2) Make them sub-pages of `/agents`. (3) Add them as additional tabs in RunDetailLive.
- **Why:** Gossip and Mesh are coordination modes — properties of a run, not standalone concepts. Users don't "go to gossip" — they launch a run that uses gossip and then observe it. Embedding the visualization in the run detail page matches this mental model. It also eliminates the config/launch duplication (GossipLive and MeshLive each duplicate the YAML editor from NewRunLive).
- **Tradeoff acknowledged:** RunDetailLive is already 4,400 LOC. Adding mode-specific rendering will grow it further. This should be mitigated by extracting gossip/mesh visualizations into dedicated component modules (`gossip_components.ex`, `mesh_components.ex`) that are called from RunDetailLive but defined separately.

### Decision 3: Rename "Dashboard" to "Overview" and "New Run" to "Workflows"

- **Decision:** Use "Overview" instead of "Dashboard" and "Workflows" instead of "New Run" for sidebar labels.
- **Alternatives considered:** Keep "Dashboard" as-is; use "Compose" or "Launch" instead of "Workflows."
- **Why:** "Overview" is more specific than "Dashboard" (which could mean anything). "Workflows" frames the page around the user's artifact (the workflow definition) rather than the action (creating a run). It also future-proofs the page for saved workflows, templates, etc.
- **Tradeoff acknowledged:** Users familiar with the current UI need to relearn nav labels. Mitigated by redirects and the reduced nav count making discovery trivial.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: RunDetailLive becomes too large after absorbing protocol views
- **Risk:** RunDetailLive is already 4,400 LOC. Adding gossip topology and mesh membership rendering could push it past maintainability limits.
- **Impact:** Developer velocity slows; bugs become harder to isolate; compile times increase.
- **Mitigation:** Extract protocol-specific rendering into dedicated component modules (`GossipComponents`, `MeshComponents`) that are `import`ed into RunDetailLive. The Component Architect should define this boundary. RunDetailLive calls `<.gossip_overview .../>` — it doesn't contain the rendering logic itself.
- **Validation time:** < 10 minutes — check that gossip/mesh rendering can be cleanly extracted into function components by reviewing GossipLive and MeshLive render functions.

### Risk 2: Gossip/Mesh launch flow loses parity when merged into WorkflowsLive
- **Risk:** GossipLive and MeshLive each have their own validate/launch flow that knows about `Cortex.Gossip.SessionRunner` and `Cortex.Mesh.SessionRunner`. Merging into WorkflowsLive could break the launch path for non-DAG modes.
- **Impact:** Users cannot launch gossip or mesh runs from the UI.
- **Mitigation:** WorkflowsLive should detect the coordination mode from the parsed YAML config and dispatch to the appropriate SessionRunner. This is a backend concern (Runner module already has mode detection). Verify by reading the existing launch code in GossipLive and MeshLive to confirm they follow the same pattern as NewRunLive.
- **Validation time:** < 10 minutes — read the `handle_event("launch", ...)` in all three LiveViews and confirm they can be unified.

### Risk 3: Global jobs view has users who depend on cross-run visibility
- **Risk:** Removing `/jobs` and scoping jobs to per-run detail tabs means users lose the ability to see all internal jobs across runs in one place.
- **Impact:** Users who monitor internal agent jobs (coordinator, summary, debug) across multiple runs lose a workflow.
- **Mitigation:** The Overview page could add a "Recent Jobs" section (similar to "Recent Runs") if this becomes a need. For MVP, per-run scoping is correct — jobs are tightly coupled to their parent run. Monitor user feedback post-launch.
- **Validation time:** < 5 minutes — check if any external tooling or automation hits the `/jobs` route.

### Risk 4: Old route redirects break bookmarks or automation
- **Risk:** Users or scripts that have bookmarked `/gossip`, `/mesh`, `/cluster`, or `/jobs` get redirected unexpectedly.
- **Impact:** Confusion; potential broken automation if any exists.
- **Mitigation:** Use 302 (temporary) redirects initially, with a flash message explaining the change. Upgrade to 301 (permanent) after a transition period. Document the change in the CHANGELOG.
- **Validation time:** < 5 minutes — verify no CI/CD or monitoring tools hit the old routes.

---

## Recommended API Surface

Covered in the "APIs" section above. Summary:

| Endpoint | LiveView Module | Purpose |
|----------|----------------|---------|
| `GET /` | `OverviewLive` | System overview + recent runs |
| `GET /agents` | `AgentsLive` | Connected agent fleet |
| `GET /agents/:id` | `AgentDetailLive` | Single agent detail (stretch) |
| `GET /workflows` | `WorkflowsLive` | Compose + launch runs |
| `GET /runs` | `RunsLive` | Run list + compare toggle |
| `GET /runs/:id` | `RunDetailLive` | Run detail (8 tabs) |
| `GET /runs/:id/teams/:name` | `TeamDetailLive` | Team detail |

---

## Folder Structure

```
lib/cortex_web/
├── router.ex                          # Updated route table + redirect plugs
├── layouts/
│   ├── root.html.heex                 # Updated sidebar (4 items)
│   └── app.html.heex                  # Unchanged
├── live/
│   ├── overview_live.ex               # Renamed from dashboard_live.ex
│   ├── agents_live.ex                 # New (content from cluster_live.ex)
│   ├── agent_detail_live.ex           # New (stretch goal)
│   ├── workflows_live.ex              # Renamed from new_run_live.ex
│   ├── runs_live.ex                   # Renamed from run_list_live.ex + absorbs run_compare_live.ex
│   ├── run_detail_live.ex             # Existing — adds protocol-conditional overview rendering
│   ├── team_detail_live.ex            # Unchanged
│   └── helpers/
│       └── dag_layout.ex              # Unchanged
├── components/
│   ├── core_components.ex             # Unchanged
│   ├── dag_components.ex              # Unchanged
│   ├── gossip_components.ex           # New — extracted from gossip_live.ex render
│   └── mesh_components.ex             # New — extracted from mesh_live.ex render
└── controllers/                       # Unchanged

# Deleted files:
# - lib/cortex_web/live/dashboard_live.ex       (replaced by overview_live.ex)
# - lib/cortex_web/live/run_list_live.ex         (replaced by runs_live.ex)
# - lib/cortex_web/live/run_compare_live.ex      (merged into runs_live.ex)
# - lib/cortex_web/live/new_run_live.ex          (replaced by workflows_live.ex)
# - lib/cortex_web/live/gossip_live.ex           (extracted to components, killed)
# - lib/cortex_web/live/mesh_live.ex             (extracted to components, killed)
# - lib/cortex_web/live/cluster_live.ex          (replaced by agents_live.ex)
# - lib/cortex_web/live/jobs_live.ex             (killed — jobs accessed per-run)
```

---

## Step-by-step Task Plan (4-7 small tasks)

### Task 1: Router + Sidebar + Redirects
- **Outcome:** New route table with 4 top-level routes + redirects for old routes. Sidebar renders 4 nav items.
- **Files to create/modify:**
  - `lib/cortex_web/router.ex` — new route table + redirect plugs
  - `lib/cortex_web/layouts/root.html.heex` — sidebar updated to 4 items
  - `test/cortex_web/redirects_test.exs` — redirect tests
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test test/cortex_web/redirects_test.exs`
- **Suggested commit message:** `refactor(web): restructure routes to 4-item nav with legacy redirects`

### Task 2: Rename DashboardLive → OverviewLive, NewRunLive → WorkflowsLive, RunListLive → RunsLive
- **Outcome:** Three LiveView modules renamed; existing behavior preserved. ClusterLive content moves to AgentsLive.
- **Files to create/modify:**
  - `lib/cortex_web/live/overview_live.ex` (rename from dashboard_live.ex)
  - `lib/cortex_web/live/workflows_live.ex` (rename from new_run_live.ex)
  - `lib/cortex_web/live/runs_live.ex` (rename from run_list_live.ex)
  - `lib/cortex_web/live/agents_live.ex` (rename from cluster_live.ex)
  - Delete old files
  - Update any `import` or `alias` references
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test`
- **Suggested commit message:** `refactor(web): rename LiveView modules to match new nav structure`

### Task 3: Merge RunCompareLive into RunsLive
- **Outcome:** RunsLive supports two view modes (list and compare) toggled via query param. RunCompareLive deleted.
- **Files to create/modify:**
  - `lib/cortex_web/live/runs_live.ex` — add compare view mode
  - Delete `lib/cortex_web/live/run_compare_live.ex`
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test test/cortex_web/live/`
- **Suggested commit message:** `refactor(web): merge run compare view into runs list page`

### Task 4: Extract gossip/mesh components from standalone LiveViews
- **Outcome:** Gossip and mesh visualization logic extracted into reusable function components. Standalone pages deleted.
- **Files to create/modify:**
  - `lib/cortex_web/components/gossip_components.ex` — new component module
  - `lib/cortex_web/components/mesh_components.ex` — new component module
  - Delete `lib/cortex_web/live/gossip_live.ex`
  - Delete `lib/cortex_web/live/mesh_live.ex`
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test`
- **Suggested commit message:** `refactor(web): extract gossip/mesh visualizations into component modules`

### Task 5: Integrate protocol views into RunDetailLive + kill JobsLive
- **Outcome:** RunDetailLive's Overview tab conditionally renders gossip/mesh components based on `run.mode`. Global JobsLive deleted (jobs accessed per-run).
- **Files to create/modify:**
  - `lib/cortex_web/live/run_detail_live.ex` — conditional protocol rendering in overview tab
  - Delete `lib/cortex_web/live/jobs_live.ex`
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test`
  - Manual: launch a gossip run, verify topology renders in run detail
- **Suggested commit message:** `feat(web): render protocol-specific views in run detail overview tab`

### Task 6: Unify workflow launch flow for all coordination modes
- **Outcome:** WorkflowsLive detects coordination mode from YAML config and dispatches to the correct SessionRunner (DAG, Gossip, or Mesh).
- **Files to create/modify:**
  - `lib/cortex_web/live/workflows_live.ex` — mode detection + dispatch
- **Exact verification commands:**
  - `mix compile --warnings-as-errors`
  - `mix test`
  - Manual: launch a gossip config from `/workflows`, verify it creates a gossip-mode run
- **Suggested commit message:** `feat(web): unify workflow launcher to support all coordination modes`

---

## CLAUDE.md Contributions (do NOT write the file; propose content)

### From Information Architect

**Add to Architecture section:**
```
- Web Routes: 4 top-level (/, /agents, /workflows, /runs) + run detail + team detail
- Legacy routes (/gossip, /mesh, /cluster, /jobs) redirect to new homes
```

**Add to Commands section:**
```bash
mix test test/cortex_web/redirects_test.exs  # route redirect tests
```

**Add to "Before You Commit" checklist:**
```
6. All legacy routes still redirect correctly (mix test test/cortex_web/redirects_test.exs)
```

**Add guardrail:**
```
- Do NOT add new top-level nav items without updating the Information Architecture doc
- Protocol-specific views belong in RunDetailLive (via components), not as standalone pages
```

---

## EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

### Navigation Architecture
- Cortex UI is organized around 4 user intents: Overview (health check), Agents (fleet management), Workflows (compose + launch), Runs (monitor + debug)
- Protocol-specific views (gossip topology, mesh membership, DAG graph) are contextual to a run, rendered in RunDetailLive's Overview tab based on `run.mode`
- The coordination mode (DAG/Mesh/Gossip) is a property of a run, not a top-level navigation concept

### Key Engineering Decisions
- Standalone protocol pages (GossipLive, MeshLive) were killed to eliminate duplication and match the user's mental model (protocols are run properties)
- RunCompareLive was absorbed into RunsLive as a view toggle to reduce top-level page count
- JobsLive was killed because internal agent jobs are implementation details of a specific run

### Migration
- All old routes redirect (302) to their new homes
- No backend changes — restructure is purely web layer
- Sidebar reduced from 7 items to 4

### Limits of MVP
- Agent detail page (`/agents/:id`) is a stretch goal — depends on Gateway.Registry supporting per-agent queries
- Run detail tabs are not deep-linkable via URL (tab state is client-side LiveView assigns)
- Cross-run jobs view is lost; acceptable because jobs are tightly coupled to their parent run

---

## READY FOR APPROVAL
