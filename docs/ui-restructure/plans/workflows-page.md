# Workflows Page Plan

## You are in PLAN MODE.

### Project
I want to do a **UI Restructure** of the Cortex web layer.

**Goal:** Evolve the current NewRunLive into a unified **Workflows page** that serves as the primary entry point for composing and launching multi-agent work across all three coordination modes (DAG, Mesh, Gossip) — replacing three separate launcher UIs with one coherent workflow composition experience.

### Role + Scope
- **Role:** Workflows Page Designer
- **Scope:** Own the design of `/workflows` — the workflow composition and launch page. This includes the coordination mode selector, agent picker, mode-specific config panels, YAML editor, validation preview, and launch flow. Does NOT own the Agents page (agent fleet view), Runs page (monitoring), or shared component system (Component Architect owns that).
- **File you will write:** `docs/ui-restructure/plans/workflows-page.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1: Multi-mode launch** — Users can compose and launch workflows in any of the three coordination modes (DAG, Mesh, Gossip) from a single page, replacing the current split across NewRunLive (`/workflows`), GossipLive (`/gossip`), and MeshLive (`/mesh`).
- **FR2: Two composition paths** — Support both YAML-first (paste/load, exists today) and visual composition (select agents, set dependencies, choose mode). Both paths converge at validation and launch.
- **FR3: Coordination mode selector** — A prominent mode picker (DAG / Mesh / Gossip) that switches the visible config panel and agent configuration UI to match the selected mode's schema.
- **FR4: Agent picker** — For visual composition, users select from connected agents (via Gateway Registry) filtered by capability. For DAG mode, agents map to team leads. For Mesh/Gossip, agents are peers.
- **FR5: Mode-specific configuration** — DAG: team dependencies, lead/member roles, tasks. Mesh: heartbeat/suspect/dead timeouts, coordinator toggle. Gossip: rounds, topology, exchange interval, seed knowledge, coordinator toggle.
- **FR6: Validation and preview** — Before launch, validate the composed config (or YAML) and show a preview. DAG mode shows the dependency graph (existing DAGComponents). Mesh/Gossip show the agent list with mode-specific settings summary.
- **FR7: Workspace path** — Configurable workspace directory, same behavior as today (UI field OR YAML field, not both).
- **FR8: Launch and redirect** — On launch, create a Run record, spawn orchestration, and redirect to the run detail page (`/runs/:id`).
- **FR9: Quick-start templates** — Provide a small set of starter templates (one per mode) that pre-fill the YAML editor, giving users a working example to modify rather than starting from scratch.

- **Tests required:** LiveView unit tests for mode switching, form validation, agent picker filtering, YAML-to-visual conversion, and launch flow. Integration test: compose visually, validate, launch, verify redirect and Run record creation.
- **Metrics required:** N/A for web layer (existing telemetry covers run creation).

## Non-Functional Requirements

- Language/runtime: Elixir/Phoenix LiveView, Tailwind CSS (dark mode)
- Local dev: `mix phx.server` on port 4000
- Observability: existing telemetry covers run creation; no new metrics needed for the UI layer
- Safety: YAML parsing errors must not crash the LiveView; all user input sanitized through existing Loader modules
- Documentation: CLAUDE.md contributions for workflow-related dev commands
- Performance: mode switching and agent list rendering must feel instant (<100ms); agent picker should handle 50+ agents without lag

---

## Assumptions / System Model

- **Deployment environment:** Local dev via `mix phx.server`; the page works identically in production
- **Failure modes:** YAML parse errors (handled by Loader), Gateway Registry unavailable (agent picker shows empty state with guidance), validation failures (shown inline)
- **Delivery guarantees:** N/A (web UI, not a data pipeline)
- **Multi-tenancy:** None for MVP
- **Backend stability:** All three config loaders (`Cortex.Orchestration.Config.Loader`, `Cortex.Mesh.Config.Loader`, `Cortex.Gossip.Config.Loader`) and session runners (`Runner`, `Mesh.SessionRunner`, `Gossip.SessionRunner`) are stable and unchanged. The Workflows page is purely a new frontend to existing launch APIs.
- **Agent availability:** The agent picker queries `Cortex.Gateway.Registry.list()` for connected agents. If no agents are connected, the picker shows an empty state. Visual composition for DAG mode does not require connected agents (teams can specify agents by name/role without a live connection).

---

## Data Model (as relevant to your role)

No new backend data models. The Workflows page composes existing config structs:

- **DAG mode** → `Cortex.Orchestration.Config` (name, defaults, teams with leads/members/tasks/depends_on, workspace_path)
- **Mesh mode** → `Cortex.Mesh.Config` (name, defaults, mesh settings, agents with name/role/prompt, cluster_context)
- **Gossip mode** → `Cortex.Gossip.Config` (name, defaults, gossip settings, agents with name/topic/prompt, seed_knowledge, cluster_context)

**LiveView assigns (new state shape):**

```
%{
  # Mode
  mode: :dag | :mesh | :gossip,         # currently selected coordination mode

  # Composition path
  composition_mode: :yaml | :visual,     # which editor is active

  # YAML path (exists today, unchanged)
  yaml_content: "",
  file_path: "",

  # Shared config
  project_name: "",
  workspace_path: "",
  model: "sonnet",
  max_turns: 200,
  timeout_minutes: 30,

  # DAG-specific visual state
  dag_teams: [],                         # list of team maps for visual builder
  dag_edges: [],                         # dependency edges for preview

  # Mesh-specific visual state
  mesh_agents: [],                       # selected agents for mesh
  mesh_settings: %{heartbeat: 30, suspect: 90, dead: 180, coordinator: false},
  cluster_context: "",

  # Gossip-specific visual state
  gossip_agents: [],                     # selected agents for gossip
  gossip_settings: %{rounds: 5, topology: :random, interval: 60, coordinator: false},
  seed_knowledge: [],

  # Connected agents from Gateway Registry
  available_agents: [],                  # from Gateway.Registry.list()
  agent_filter: "",                      # capability/name search string

  # Validation
  validation_result: nil,
  config: nil,
  tiers: [],                             # DAG preview tiers
  edges: [],                             # DAG preview edges
  errors: [],
  warnings: [],

  # Templates
  active_template: nil
}
```

- Validation rules: delegated to existing Loader/Validator modules per mode
- Versioning: N/A (no persistence of workflow drafts in MVP)
- Persistence: existing `Cortex.Store.create_run/1` for launched runs

---

## APIs (as relevant to your role)

No new backend APIs. The Workflows page uses existing APIs:

### Existing APIs consumed

- `Cortex.Gateway.Registry.list()` — returns `[RegisteredAgent.t()]` for the agent picker
- `Cortex.Orchestration.Config.Loader.load_string/1` — validates DAG YAML
- `Cortex.Mesh.Config.Loader.load_string/1` — validates Mesh YAML
- `Cortex.Gossip.Config.Loader.load_string/1` — validates Gossip YAML
- `Cortex.Store.create_run/1` — creates Run record
- `Cortex.Orchestration.Runner.run/2` — launches DAG run
- `Cortex.Mesh.SessionRunner.run/2` — launches Mesh run
- `Cortex.Gossip.SessionRunner.run/2` — launches Gossip run

### LiveView events (new)

| Event | Params | Behavior |
|-------|--------|----------|
| `select_mode` | `%{"mode" => "dag"\|"mesh"\|"gossip"}` | Switch coordination mode, update visible config panel |
| `select_composition` | `%{"mode" => "yaml"\|"visual"}` | Toggle between YAML editor and visual composer |
| `form_changed` | form params | Update assigns from form inputs (existing, extended) |
| `add_agent` | `%{"agent_id" => id}` | Add a connected agent to the current mode's agent list |
| `remove_agent` | `%{"agent_id" => id}` | Remove an agent from the current mode's agent list |
| `filter_agents` | `%{"query" => str}` | Filter available agents by name/capability |
| `add_dag_team` | `%{}` | Add a blank team to the DAG visual builder |
| `remove_dag_team` | `%{"name" => str}` | Remove a team from the DAG visual builder |
| `update_dag_team` | `%{"name" => str, ...}` | Update team lead/tasks/depends_on |
| `load_template` | `%{"template" => name}` | Pre-fill YAML editor with a starter template |
| `validate` | form params | Validate config (existing, extended for all modes) |
| `launch` | `%{}` | Launch run (existing, extended for all modes) |

---

## Architecture / Component Boundaries (as relevant)

### Components this page uses

1. **Mode selector** — Three-button toggle (DAG / Mesh / Gossip) with icons and short descriptions. Owned by Component Architect; this plan specifies the interface.
   - Inputs: `selected_mode`, `on_select` event name
   - Visual: pill/tab group, selected state highlighted in cortex color

2. **Composition path toggle** — Two-way switch: "YAML" | "Visual". Simple inline component.

3. **YAML editor panel** — Existing textarea with syntax-highlighted-ish monospace styling. Already implemented in NewRunLive, keep as-is but add mode-aware placeholder text.

4. **Agent picker panel** — Used in visual composition mode. Queries available agents, filters by capability, shows selectable cards. Agent card display is owned by Component Architect.
   - Inputs: `available_agents`, `selected_agents`, `filter`, `on_add`, `on_remove` events
   - Displays: agent name, role, capabilities, status, transport badge

5. **DAG team builder** — Visual composition specific to DAG mode. Add/remove teams, set lead role, add tasks, set dependencies via dropdowns. Shows live DAG preview using existing `DAGComponents.dag_graph/1`.

6. **Mesh config panel** — Settings for mesh mode: heartbeat interval, suspect/dead timeouts, coordinator toggle, cluster context textarea.

7. **Gossip config panel** — Settings for gossip mode: rounds, topology selector (full_mesh/ring/random), exchange interval, coordinator toggle, seed knowledge entries, cluster context textarea.

8. **Validation result panel** — Existing error/warning display, plus config preview and DAG graph. Extended to show mode-appropriate previews for Mesh/Gossip.

9. **Workspace/defaults panel** — Project name, workspace path, model selector, max turns, timeout. Shared across all modes.

### Page layout (2-column)

```
+--------------------------------------------------+
| Workflows                                        |
| [DAG] [Mesh] [Gossip]    mode selector           |
+--------------------------------------------------+
| Left Column              | Right Column           |
|                          |                        |
| [YAML | Visual] toggle   | Validation Results     |
|                          |   - Errors / Warnings  |
| (if YAML):               |   - Config Preview     |
|   YAML textarea          |   - DAG Graph (DAG)    |
|   File path input        |   - Agent List (M/G)   |
|   [Load Template v]      |                        |
|                          |                        |
| (if Visual):             |                        |
|   Project Name           |                        |
|   Agent Picker           |                        |
|   Mode-specific config   |                        |
|   Workspace Path         |                        |
|   Defaults               |                        |
|                          |                        |
| [Validate] [Launch]      |                        |
+--------------------------------------------------+
```

### How config changes propagate

- Mode switch resets mode-specific visual state but preserves shared state (project name, workspace, defaults)
- YAML/Visual toggle: switching to YAML from Visual generates YAML from the current visual state (one-way serialization). Switching to Visual from YAML attempts to parse the YAML into visual state; if it fails, shows a warning and falls back to YAML-only mode.
- Agent picker subscribes to `Cortex.Gateway.Events` PubSub for live agent connect/disconnect updates.

### Concurrency model

- LiveView process handles all state; no background GenServers needed for the composition UI
- Launch spawns orchestration via `Task.start/1` (existing pattern from NewRunLive)

---

## Correctness Invariants (must be explicit)

1. **Mode determines config struct.** Selecting DAG mode produces `Orchestration.Config`, Mesh produces `Mesh.Config`, Gossip produces `Gossip.Config`. No cross-contamination.
2. **Validation uses the correct Loader.** DAG YAML goes through `Orchestration.Config.Loader`, Mesh through `Mesh.Config.Loader`, Gossip through `Gossip.Config.Loader`. The page dispatches based on `mode` assign.
3. **Launch uses the correct SessionRunner.** DAG launches via `Orchestration.Runner.run/2`, Mesh via `Mesh.SessionRunner.run/2`, Gossip via `Gossip.SessionRunner.run/2`.
4. **YAML and visual cannot conflict.** Only the active composition path's data is used for validation and launch. If in YAML mode, visual state is ignored. If in Visual mode, YAML is generated from visual state.
5. **Workspace path cannot be set in both UI and YAML.** Existing validation from NewRunLive applies.
6. **Agent picker only shows connected agents.** Disconnected agents are removed from the available list in real-time via PubSub.
7. **DAG dependency graph is acyclic.** Validated by existing `Config.Validator` which uses Kahn's algorithm for cycle detection.
8. **All form inputs are sanitized through existing Loader modules.** No raw user input reaches the backend without going through YAML parse + validation.

---

## Tests

### Unit tests

- `test/cortex_web/live/workflows_live_test.exs`:
  - Mode switching: mount defaults to DAG, switching to Mesh/Gossip updates assigns and visible panel
  - Composition toggle: YAML/Visual switch preserves shared state
  - DAG visual builder: add/remove teams, set dependencies, generate valid YAML
  - Agent picker: filter by capability, add/remove agents from selection
  - Validation dispatch: DAG YAML validated by Orchestration loader, Mesh by Mesh loader, Gossip by Gossip loader
  - Launch dispatch: correct runner invoked per mode
  - Template loading: selecting a template populates YAML editor
  - Error display: validation errors shown correctly per mode
  - Workspace conflict: error when workspace set in both YAML and UI form

### Integration tests

- `test/cortex_web/live/workflows_live_integration_test.exs`:
  - Full DAG flow: paste YAML, validate, see DAG preview, launch, verify Run created and redirect to `/runs/:id`
  - Full Mesh flow: paste mesh YAML, validate, launch, verify Run created with mode "mesh"
  - Full Gossip flow: paste gossip YAML, validate, launch, verify Run created with mode "gossip"
  - Visual composition: build a 2-team DAG visually, validate, verify generated YAML is valid

### Commands

```bash
mix test test/cortex_web/live/workflows_live_test.exs
mix test test/cortex_web/live/workflows_live_integration_test.exs
mix test test/cortex_web/live/ --trace
```

---

## Benchmarks + "Success"

N/A — This is a UI page, not a data processing pipeline. Performance is measured by user experience: mode switching and form interactions should feel instant. The existing DAGLayout calculations are already fast (sub-millisecond for reasonable team counts). No new benchmarking infrastructure needed.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Unified LiveView module vs. separate modules per mode

- **Decision:** Single `WorkflowsLive` module with mode-specific render functions extracted into helper modules (e.g., `WorkflowsLive.DAGPanel`, `WorkflowsLive.MeshPanel`, `WorkflowsLive.GossipPanel`).
- **Alternatives considered:** (A) Three separate LiveView modules (`WorkflowDAGLive`, `WorkflowMeshLive`, `WorkflowGossipLive`) with a parent layout. (B) One monolithic LiveView like the current `RunDetailLive` (4,400 LOC).
- **Why:** A single LiveView simplifies state management for shared concerns (project name, workspace, defaults) and avoids page navigation when switching modes. But we extract mode-specific panels into helper modules to prevent the LOC explosion that happened with RunDetailLive. The parent LiveView handles events and shared state; helpers handle rendering.
- **Tradeoff acknowledged:** Mode-specific logic in the parent LiveView's `handle_event` will still need `case mode` dispatching, adding some conditional complexity. This is acceptable because the events are well-typed and the pattern is clear.

### Decision 2: Visual-to-YAML is one-way (generate), not bidirectional sync

- **Decision:** Visual composition generates YAML when the user switches to YAML mode or validates. YAML-to-visual parsing is attempted but treated as best-effort — if it fails, the user stays in YAML mode.
- **Alternatives considered:** Full bidirectional sync where every YAML edit updates the visual builder and vice versa.
- **Why:** Bidirectional sync is enormously complex (YAML supports comments, arbitrary ordering, anchors/aliases) and would be fragile. One-way generation is simple and reliable. Users who want visual composition use visual mode; users who want YAML use YAML mode. The generated YAML is clean and deterministic.
- **Tradeoff acknowledged:** Users cannot freely switch between modes while editing. If they start in YAML mode with complex YAML, switching to Visual may lose comments or formatting. This is acceptable for MVP — advanced YAML users are unlikely to need the visual builder.

### Decision 3: Agent picker is optional, not required

- **Decision:** The agent picker shows connected agents from the Gateway Registry as a convenience, but visual composition does not require live-connected agents. Users can type agent names/roles manually.
- **Alternatives considered:** Require agents to be connected before they can be added to a workflow.
- **Why:** In development and testing, users often compose workflows before deploying agents. Requiring live connections would block the primary use case. The picker is a convenience for production use where agents are already running.
- **Tradeoff acknowledged:** Users can compose workflows that reference agents that don't exist yet, which will fail at runtime. This is acceptable because the existing runner already handles this failure mode gracefully.

### Decision 4: Templates as static YAML strings, not a template engine

- **Decision:** Quick-start templates are hardcoded YAML strings (one per mode) stored as module attributes in the LiveView.
- **Alternatives considered:** (A) Template files on disk. (B) User-saved templates persisted in SQLite. (C) A template engine with variable substitution.
- **Why:** For MVP, 3 static templates are sufficient to demonstrate the workflow and give users a starting point. Saved templates and a template engine are future features that add persistence requirements and UI complexity.
- **Tradeoff acknowledged:** Users cannot save their own templates in MVP. This is explicitly a Phase 2 feature.

---

## Risks & Mitigations

### Risk 1: WorkflowsLive becomes another 4,400 LOC monster like RunDetailLive

- **Risk:** Three modes x two composition paths x shared config = complex state management in one module.
- **Impact:** Hard to maintain, slow to iterate, merge conflicts with other designers.
- **Mitigation:** Extract mode-specific panels into helper modules from the start (`WorkflowsLive.DAGPanel`, `.MeshPanel`, `.GossipPanel`). Keep the parent LiveView under 300 LOC by delegating rendering and keeping event handlers thin (dispatch to private functions per mode).
- **Validation time:** 10 minutes — measure LOC after implementing Task 2 (mode skeleton). If parent exceeds 300 LOC, refactor before continuing.

### Risk 2: Visual-to-YAML generation produces invalid YAML for edge cases

- **Risk:** The YAML generated from visual composition state might not pass validation through the existing Loaders.
- **Impact:** Users compose visually, hit "Validate", get confusing errors from the YAML layer.
- **Mitigation:** Generate YAML by building the Config struct first, then serializing to YAML. Validate the struct directly (not the YAML string) when in visual mode. Only generate YAML for display/export, not as the validation input.
- **Validation time:** 10 minutes — write a unit test that builds a visual config, serializes to YAML, re-parses, and checks round-trip consistency.

### Risk 3: Gateway Registry unavailable breaks the agent picker

- **Risk:** `Cortex.Gateway.Registry.list()` raises or returns unexpected results if the Registry GenServer isn't running (e.g., in test environments, dev without sidecar started).
- **Impact:** LiveView crashes on mount.
- **Mitigation:** Use the existing `safe_list_*` pattern from ClusterLive/MeshLive — wrap Registry calls in `try/rescue` returning `[]` on failure. Show an empty state message: "No agents connected. Start a sidecar to see agents here."
- **Validation time:** 5 minutes — test with Registry stopped.

### Risk 4: Existing GossipLive/MeshLive launch logic is duplicated

- **Risk:** The launch flow for Mesh and Gossip currently lives in GossipLive and MeshLive. If we duplicate this logic into WorkflowsLive, we create maintenance burden.
- **Impact:** Bug fixes need to be applied in multiple places; behavior diverges over time.
- **Mitigation:** Extract the launch logic (write YAML to temp file, call SessionRunner, handle result, update Store) into a shared `WorkflowLauncher` helper module that all three current pages and the new WorkflowsLive can call. This is a small refactor during Task 3.
- **Validation time:** 10 minutes — verify all three modes launch correctly through the shared helper.

---

## Recommended API surface

No new backend APIs needed. The Workflows page is a new LiveView that composes existing backend APIs.

**LiveView public surface:**

```elixir
# Route
live("/workflows", WorkflowsLive, :index)
# (replaces: live("/workflows", NewRunLive, :index))

# Module
defmodule CortexWeb.WorkflowsLive do
  # mount/3 — initialize assigns, subscribe to Gateway PubSub
  # handle_event/3 — all events listed in APIs section above
  # render/1 — delegates to mode-specific panel helpers
end
```

---

## Folder structure

```
lib/cortex_web/live/
  workflows_live.ex                    # Main LiveView (event handling, mount, shared render)
  workflows_live/
    dag_panel.ex                       # DAG-specific visual builder + config panel (function components)
    mesh_panel.ex                      # Mesh-specific config panel (function components)
    gossip_panel.ex                    # Gossip-specific config panel (function components)
    agent_picker.ex                    # Agent picker component (shared across visual modes)
    templates.ex                       # Static YAML templates per mode
    launcher.ex                        # Shared launch logic extracted from NewRunLive/MeshLive/GossipLive

lib/cortex_web/components/
  dag_components.ex                    # Existing — used for DAG preview graph (no changes)
```

---

## Step-by-step task plan in small commits

### Task 1: Scaffold WorkflowsLive with mode selector

- **Outcome:** New `WorkflowsLive` module replaces `NewRunLive` at `/workflows`. Three-mode selector (DAG/Mesh/Gossip) switches visible panel. DAG mode reproduces existing NewRunLive YAML functionality exactly.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/workflows_live.ex`
  - Modify: `lib/cortex_web/router.ex` (change route from `NewRunLive` to `WorkflowsLive`)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/workflows_live_test.exs
  # Manual: visit /workflows, verify DAG mode works identically to old NewRunLive
  ```
- **Commit message:** `feat(web): scaffold WorkflowsLive with tri-mode selector`

### Task 2: Extract mode panels and add Mesh/Gossip YAML support

- **Outcome:** Mode-specific render panels extracted into helper modules. Mesh and Gossip modes accept YAML input, validate through their respective Loaders, and show validation results.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/workflows_live/dag_panel.ex`
  - Create: `lib/cortex_web/live/workflows_live/mesh_panel.ex`
  - Create: `lib/cortex_web/live/workflows_live/gossip_panel.ex`
  - Modify: `lib/cortex_web/live/workflows_live.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/workflows_live_test.exs
  # Manual: paste mesh.yaml in Mesh mode, validate; paste gossip.yaml in Gossip mode, validate
  ```
- **Commit message:** `feat(web): add Mesh/Gossip YAML validation to WorkflowsLive`

### Task 3: Extract shared launcher and wire up all three launch flows

- **Outcome:** Shared `WorkflowLauncher` module handles launch for all three modes (write temp YAML, call correct SessionRunner, create Run, redirect). All three modes can validate and launch.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/workflows_live/launcher.ex`
  - Modify: `lib/cortex_web/live/workflows_live.ex` (wire launch events)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/workflows_live_test.exs
  mix test test/cortex_web/live/workflows_live_integration_test.exs
  # Manual: launch a DAG run, a Mesh run, and a Gossip run from /workflows
  ```
- **Commit message:** `feat(web): unify launch flow across all coordination modes`

### Task 4: Add agent picker and visual composition toggle

- **Outcome:** Composition mode toggle (YAML/Visual). Agent picker component queries Gateway Registry, filters by capability, allows selection. Visual mode shows agent picker + shared config fields. Available in all three modes.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/workflows_live/agent_picker.ex`
  - Modify: `lib/cortex_web/live/workflows_live.ex` (composition toggle, visual state)
  - Modify panel helpers as needed for visual mode rendering
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/workflows_live_test.exs
  # Manual: toggle to Visual, see agent picker, filter, add/remove agents
  ```
- **Commit message:** `feat(web): add agent picker and visual composition mode`

### Task 5: DAG visual builder (team editor + dependency graph)

- **Outcome:** In DAG + Visual mode, users can add teams, set lead roles, add tasks, configure dependencies via dropdowns. Live DAG preview updates as dependencies change. Visual state generates valid YAML.
- **Files to create/modify:**
  - Modify: `lib/cortex_web/live/workflows_live/dag_panel.ex` (team builder UI)
  - Modify: `lib/cortex_web/live/workflows_live.ex` (team CRUD events, YAML generation)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/live/workflows_live_test.exs
  # Manual: build a 3-team DAG visually, validate, verify YAML, launch
  ```
- **Commit message:** `feat(web): add DAG visual builder with live dependency graph`

### Task 6: Quick-start templates and polish

- **Outcome:** Template dropdown with one starter per mode. Selecting a template populates the YAML editor. Polish: placeholder text per mode, empty states, loading indicators, keyboard accessibility for mode selector.
- **Files to create/modify:**
  - Create: `lib/cortex_web/live/workflows_live/templates.ex`
  - Modify: `lib/cortex_web/live/workflows_live.ex` (template events, polish)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix format --check-formatted
  mix credo --strict
  mix test test/cortex_web/live/workflows_live_test.exs
  ```
- **Commit message:** `feat(web): add workflow templates and polish Workflows page`

### Task 7: Cleanup — remove old standalone pages

- **Outcome:** Remove GossipLive and MeshLive YAML input / launch sections (their launch UIs are now consolidated into WorkflowsLive). Remove old NewRunLive module. Update any cross-references. Keep GossipLive/MeshLive for now if other designers plan to fold their visualization features into Runs — coordinate with Runs Consolidation Designer.
- **Files to create/modify:**
  - Delete: `lib/cortex_web/live/new_run_live.ex`
  - Modify: `lib/cortex_web/router.ex` (remove old routes if applicable)
  - Modify: any sidebar/nav references to old pages
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test
  # Verify no broken routes or dead references
  ```
- **Commit message:** `refactor(web): remove NewRunLive, consolidate launch into WorkflowsLive`

---

## CLAUDE.md contributions (proposed content, do NOT write the file)

## From Workflows Page Designer
### Coding Style
- Extract LiveView render helpers into `live/<page>_live/` subdirectory modules when a page handles multiple modes or panels
- Mode-specific event handlers should dispatch via a private `handle_<event>_for_mode/3` pattern to keep the parent LiveView thin
- Use `safe_*` wrappers (try/rescue returning default) for all Gateway Registry calls — the registry may not be running in test or dev

### Dev Commands
```bash
mix test test/cortex_web/live/workflows_live_test.exs        # Workflows page tests
mix test test/cortex_web/live/workflows_live_integration_test.exs  # launch flow integration
```

### Before You Commit (additions)
- Verify all three modes (DAG/Mesh/Gossip) validate and launch correctly
- Check that mode switching does not leak state between modes
- Ensure agent picker gracefully handles Gateway Registry being unavailable

### Guardrails
- Do not add YAML persistence or saved templates to the database without a design review
- Do not make visual composition the default — YAML-first users should not see extra steps
- Keep WorkflowsLive parent module under 400 LOC by extracting to panel helpers

---

## EXPLAIN.md contributions (proposed outline bullets)

### Flow / Architecture
- WorkflowsLive is the unified entry point for composing and launching multi-agent work
- Three coordination modes (DAG/Mesh/Gossip) are properties of a workflow, not separate pages
- Two composition paths: YAML-first for power users, Visual for discovery and learning
- Launch flow: compose -> validate (mode-aware Loader) -> preview -> launch (mode-aware SessionRunner) -> redirect to /runs/:id

### Key Engineering Decisions + Tradeoffs
- Single LiveView with extracted panel helpers prevents RunDetailLive-scale LOC bloat while keeping state management simple
- Visual-to-YAML is one-way generation, not bidirectional sync — simplicity over flexibility
- Agent picker is convenience, not requirement — workflows can reference agents that aren't connected yet
- Templates are static strings for MVP; saved templates are a future feature

### Limits of MVP + Next Steps
- MVP: YAML input for all three modes, visual composition for DAG mode, agent picker, templates
- Future: saved workflow templates, visual composition for Mesh/Gossip, drag-and-drop DAG builder, workflow versioning, re-run from a previous workflow
- Visual composition for Mesh and Gossip is simpler than DAG (flat agent lists, no dependency graph) and can be added in a follow-up

### How to Run Locally + How to Validate
- `mix phx.server` — visit http://localhost:4000/workflows
- Switch modes with the DAG/Mesh/Gossip selector
- Paste YAML or use the Visual builder, validate, and launch
- `mix test test/cortex_web/live/workflows_live_test.exs` for unit tests

---

## READY FOR APPROVAL
